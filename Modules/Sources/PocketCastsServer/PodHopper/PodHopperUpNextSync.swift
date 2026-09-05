import Foundation
import PocketCastsDataModel
import PocketCastsUtils

/// Cross device Up Next queue sync, built on server applied actions.
///
/// Devices do not send the queue. They send what the user did, and the backend applies those
/// actions in arrival order to the one canonical queue and returns the result. The properties that
/// matter fall out of that: a device that did nothing has nothing to send and therefore cannot
/// publish an empty queue over a queue somebody else built, and a device acting on a stale queue has
/// its action applied on top of the current one rather than replacing it. Device clocks stop
/// mattering, because ordering is the server's.
///
/// This replaced a whole list model where every device asserted the entire queue and timestamps
/// decided the winner. That model could not tell "the user cleared their queue" apart from "this
/// device has nothing because it has not been used", since both are an empty list.
public final class PodHopperUpNextSync {

    public static let shared = PodHopperUpNextSync()

    private let supabase: PodHopperSupabaseClient
    private let dataManager: DataManager
    private let defaults: UserDefaults

    private let workQueue = DispatchQueue(label: "au.com.podhopper.upnextsync", qos: .utility)
    private let stateLock = NSLock()

    public init(
        supabase: PodHopperSupabaseClient = .shared,
        dataManager: DataManager = .sharedManager,
        defaults: UserDefaults = UserDefaults(suiteName: PodHopperPositionSync.suiteName) ?? .standard
    ) {
        self.supabase = supabase
        self.dataManager = dataManager
        self.defaults = defaults
    }

    /// One queue entry on the wire. Keys are deliberately short and must match Android exactly or
    /// the two platforms will not interoperate. Only the uuid is required.
    struct Entry {
        let uuid: String
        let title: String?
        let podcastUuid: String?
        let feedUrl: String?
        let mediaUrl: String?
        let publishedMs: Int64?

        init?(json: [String: Any]) {
            guard let uuid = json["u"] as? String, !uuid.isEmpty else { return nil }
            self.uuid = uuid
            self.title = json["t"] as? String
            self.podcastUuid = json["p"] as? String
            self.feedUrl = json["f"] as? String
            self.mediaUrl = json["m"] as? String
            self.publishedMs = (json["d"] as? NSNumber)?.int64Value
        }

        init(episode: BaseEpisode, dataManager: DataManager) {
            uuid = episode.uuid
            title = episode.displayableTitle()
            podcastUuid = episode.parentIdentifier()
            // Populated wherever it is known, unlike Android, which leaves it null for local
            // episodes. PodHopper resolves podcasts by feed url, so an entry carrying one can be
            // resolved by a device that has never seen that podcast.
            feedUrl = dataManager.findPodcast(uuid: episode.parentIdentifier(), includeUnsubscribed: true)?.podcastUrl
            mediaUrl = episode.downloadUrl
            publishedMs = episode.publishedDate.map { Int64($0.timeIntervalSince1970 * 1000) }
        }

        var json: [String: Any] {
            [
                "u": uuid,
                "t": title ?? NSNull(),
                "p": podcastUuid ?? NSNull(),
                "f": feedUrl ?? NSNull(),
                "m": mediaUrl ?? NSNull(),
                "d": publishedMs.map { NSNumber(value: $0) } ?? NSNull(),
            ]
        }
    }

    // MARK: Recording what the user did

    /// Records a user decision to be sent on the next sync. Only genuine user decisions belong here.
    ///
    /// Deliberately NOT recorded, and each of these would corrupt the account queue if it were:
    ///
    /// - Applying the backend's own queue. That path writes PlaylistEpisode rows straight through
    ///   DataManager and never reaches these call sites, but it is worth naming.
    /// - Autoplay filling an empty queue, which is the app choosing, not the user.
    /// - The override inside addToUpNext when nothing is playing. That replaces the local queue with
    ///   a single episode, which is upstream's own long standing queue wiping bug, and it is exactly
    ///   the state a car is in after sitting unused for a week.
    /// - The clear inside endPlayback, which also runs when playback fails and the current episode
    ///   cannot be fetched. Recording it would wipe the account queue on a network hiccup.
    public func record(_ action: Action) {
        #if os(watchOS)
        // The Watch renders a snapshot the phone sends and never talks to the backend itself.
        return
        #else
        guard supabase.isLoggedIn() else { return }

        stateLock.lock()
        var pending = readActions()
        pending.append(action)
        if pending.count > Self.maxPendingActions {
            pending = Array(pending.suffix(Self.maxPendingActions))
        }
        writeActions(pending)
        stateLock.unlock()
        #endif
    }

    /// A recorded user decision. The id exists so a successful send can delete exactly what it sent,
    /// rather than everything older than some timestamp, which would swallow an action the user
    /// created while the request was in flight.
    public struct Action {
        let id: String
        let type: String
        let entry: Entry?
        let uuid: String?
        let entries: [Entry]?

        var json: [String: Any] {
            var payload: [String: Any] = ["type": type]
            if let entry { payload["entry"] = entry.json }
            if let uuid { payload["uuid"] = uuid }
            if let entries { payload["entries"] = entries.map { $0.json } }
            return payload
        }
    }

    public func playNow(episode: BaseEpisode) {
        record(Action(id: UUID().uuidString, type: "play_now", entry: Entry(episode: episode, dataManager: dataManager), uuid: nil, entries: nil))
    }

    public func playNext(episode: BaseEpisode) {
        record(Action(id: UUID().uuidString, type: "play_next", entry: Entry(episode: episode, dataManager: dataManager), uuid: nil, entries: nil))
    }

    public func playLast(episode: BaseEpisode) {
        record(Action(id: UUID().uuidString, type: "play_last", entry: Entry(episode: episode, dataManager: dataManager), uuid: nil, entries: nil))
    }

    public func remove(episodeUuid: String) {
        record(Action(id: UUID().uuidString, type: "remove", entry: nil, uuid: episodeUuid, entries: nil))
    }

    /// Used for reorders and for the user clearing the queue. The list is the queue the user meant
    /// to end up with, including whatever is playing, since the first entry is the current episode.
    public func replace(episodes: [BaseEpisode]) {
        let entries = episodes.map { Entry(episode: $0, dataManager: dataManager) }
        record(Action(id: UUID().uuidString, type: "replace", entry: nil, uuid: nil, entries: entries))
    }

    // MARK: Sync

    /// Sends pending actions and applies the queue the backend returns, in one call.
    ///
    /// Never throws. Queue sync is an addition to the sync cycle, never a precondition for it.
    public func sync() {
        #if os(watchOS)
        return
        #else
        guard supabase.isLoggedIn() else { return }
        syncBlocking()
        #endif
    }

    /// Runs the sync off the caller's thread, for the queue's own change trigger.
    public func syncSoon() {
        #if os(watchOS)
        return
        #else
        guard supabase.isLoggedIn() else { return }
        workQueue.async { [weak self] in
            self?.syncBlocking()
        }
        #endif
    }

    private func syncBlocking() {
        stateLock.lock()
        let sending = readActions()
        stateLock.unlock()

        do {
            let payload: [String: Any] = [
                "p_actions": sending.map { $0.json },
                "p_device_id": PodHopperPositionSync.shared.deviceInstallId(),
                "p_device_name": PodHopperPositionSync.shared.deviceDisplayName(),
            ]
            let response = try supabase.rpc(function: Self.function, body: payload)

            // Only now that the call succeeded, and only the actions actually sent, so an action the
            // user created while this was in flight survives.
            if !sending.isEmpty {
                let sentIds = Set(sending.map { $0.id })
                stateLock.lock()
                let remaining = readActions().filter { !sentIds.contains($0.id) }
                writeActions(remaining)
                stateLock.unlock()
            }

            let version = (response["version"] as? NSNumber)?.int64Value ?? 0
            let raw = (response["episodes"] as? [[String: Any]]) ?? []
            let entries = raw.compactMap { Entry(json: $0) }

            // A brand new account that has never held a queue, on a device that has one. Actions are
            // only recorded while signed in, so a queue built before signing in has nothing behind
            // it. Guarded so it can only ever fill an empty account, never overwrite one.
            if sending.isEmpty, version == 0, entries.isEmpty {
                if let playback = ServerConfig.shared.playbackDelegate {
                    let local = playback.allEpisodesInQueue(includeNowPlaying: true)
                    if !local.isEmpty {
                        FileLog.shared.addMessage("PodHopper up next: seeding a new account with this device's queue")
                        replace(episodes: local)
                        writeVersion(version)
                        return
                    }
                }
            }

            // Nothing was sent and the queue has not moved since this device last applied it.
            if sending.isEmpty, let applied = readVersion(), applied == version {
                return
            }

            applyRemoteQueue(entries)
            writeVersion(version)
        } catch {
            // Actions stay recorded for the next sync.
            FileLog.shared.addMessage("PodHopper up next sync failed, \(sending.count) action(s) still queued: \(error)")
        }
    }

    // MARK: Apply

    /// Applies the backend's queue to this device, preserving the episode playing right now.
    ///
    /// The reconcile is adapted from the Pocket Casts era UpNextSyncTask, which had years of real
    /// use behind it: existing entries are moved rather than rebuilt, and the queue is snapshotted
    /// before it changes. Entries this device cannot resolve are skipped for display only. Nothing
    /// is lost by skipping them, because this device never sends a list and so cannot delete them.
    private func applyRemoteQueue(_ remoteEntries: [Entry]) {
        guard let playback = ServerConfig.shared.playbackDelegate else { return }

        let localUuids = playback.allEpisodesInQueue(includeNowPlaying: true).map { $0.uuid }
        let entries = preservePlayingEpisode(remoteEntries, playback: playback)

        if entries.map({ $0.uuid }) == localUuids { return }

        dataManager.snapshotUpNext()

        let episodePlayingBefore = playback.currentEpisode()
        var resolvedUuids = [String]()

        for (index, entry) in entries.enumerated() {
            if let existing = dataManager.findPlaylistEpisode(uuid: entry.uuid) {
                if existing.episodePosition != Int32(index) {
                    existing.episodePosition = Int32(index)
                    dataManager.save(playlistEpisode: existing)
                }
                resolvedUuids.append(entry.uuid)
                continue
            }

            if let localEpisode = dataManager.findBaseEpisode(uuid: entry.uuid) {
                let newEpisode = PlaylistEpisode()
                newEpisode.episodePosition = Int32(index)
                newEpisode.episodeUuid = entry.uuid
                newEpisode.podcastUuid = localEpisode.parentIdentifier()
                newEpisode.title = localEpisode.displayableTitle()
                dataManager.save(playlistEpisode: newEpisode)
                resolvedUuids.append(entry.uuid)
            }
        }

        dataManager.deleteAllUpNextEpisodesNotIn(uuids: resolvedUuids)

        playback.queueRefreshList(checkForAutoDownload: true)
        playback.upNextQueueChanged()

        if let episodePlayingBefore, playback.isNowPlayingEpisode(episodeUuid: episodePlayingBefore.uuid) == false {
            playback.playingEpisodeChangedExternally()
        } else if episodePlayingBefore == nil, !resolvedUuids.isEmpty {
            playback.playingEpisodeChangedExternally()
        } else if episodePlayingBefore != nil, resolvedUuids.isEmpty {
            playback.playingEpisodeChangedExternally()
        }
    }

    /// Keeps the episode playing right now at the head, applying the backend's order behind it, so a
    /// remote queue can never move the scrubber out from under a listener.
    private func preservePlayingEpisode(_ entries: [Entry], playback: ServerPlaybackDelegate) -> [Entry] {
        guard playback.playing(), let playing = playback.currentEpisode() else { return entries }
        if entries.first?.uuid == playing.uuid { return entries }

        var list = entries.filter { $0.uuid != playing.uuid }
        list.insert(Entry(episode: playing, dataManager: dataManager), at: 0)
        return list
    }

    // MARK: Local state

    private func readActions() -> [Action] {
        guard let data = defaults.data(forKey: Self.actionsKey),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return raw.compactMap { item in
            guard let id = item["id"] as? String, let type = item["type"] as? String else { return nil }
            let entry = (item["entry"] as? [String: Any]).flatMap { Entry(json: $0) }
            let entries = (item["entries"] as? [[String: Any]])?.compactMap { Entry(json: $0) }
            return Action(id: id, type: type, entry: entry, uuid: item["uuid"] as? String, entries: entries)
        }
    }

    private func writeActions(_ actions: [Action]) {
        if actions.isEmpty {
            defaults.removeObject(forKey: Self.actionsKey)
            return
        }
        let raw: [[String: Any]] = actions.map { action in
            var item: [String: Any] = ["id": action.id, "type": action.type]
            if let entry = action.entry { item["entry"] = entry.json }
            if let uuid = action.uuid { item["uuid"] = uuid }
            if let entries = action.entries { item["entries"] = entries.map { $0.json } }
            return item
        }
        if let data = try? JSONSerialization.data(withJSONObject: raw) {
            defaults.set(data, forKey: Self.actionsKey)
        }
    }

    private func readVersion() -> Int64? {
        (defaults.object(forKey: Self.versionKey) as? NSNumber)?.int64Value
    }

    private func writeVersion(_ version: Int64) {
        defaults.set(NSNumber(value: version), forKey: Self.versionKey)
    }

    /// Clears everything this device remembers about the queue, so the next sign in starts fresh.
    public func clearLocalSyncState() {
        defaults.removeObject(forKey: Self.actionsKey)
        defaults.removeObject(forKey: Self.versionKey)
    }

    private static let function = "apply_up_next_actions"
    private static let actionsKey = "up_next_actions"
    private static let versionKey = "up_next_version"
    private static let maxPendingActions = 500
}
