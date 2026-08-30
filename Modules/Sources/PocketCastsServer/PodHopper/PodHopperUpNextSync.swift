import Foundation
import PocketCastsDataModel
import PocketCastsUtils

/// Cross device Up Next queue sync.
///
/// One row per user holds the whole ordered queue. Two different orderings cannot be meaningfully
/// merged, so the rule is the same one the position sync uses: freshest write wins, whole list.
///
/// The reconcile logic here is adapted from the Pocket Casts era UpNextSyncTask, which had years of
/// real use behind it. What changed is the transport (Supabase rather than the Pocket Casts API),
/// the entry type (a plain struct rather than protobuf), and the treatment of entries this device
/// cannot resolve, which are now held rather than dropped.
///
/// The engine lives in the shared module so the phone and CarPlay (same process) both use it. The
/// Watch app needs nothing: it renders a snapshot the phone sends over WatchConnectivity, and
/// WatchManager already reserializes that snapshot when upNextQueueChanged fires, which is exactly
/// what applying a remote queue posts.
public final class PodHopperUpNextSync {

    public static let shared = PodHopperUpNextSync()

    private let supabase: PodHopperSupabaseClient
    private let dataManager: DataManager
    private let defaults: UserDefaults

    private let workQueue = DispatchQueue(label: "au.com.podhopper.upnextsync", qos: .utility)

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
    /// the two platforms will not interoperate. Every field except the uuid may be null.
    struct Entry {
        let uuid: String
        let title: String?
        let podcastUuid: String?
        let feedUrl: String?
        let mediaUrl: String?
        let publishedMs: Int64?

        init(uuid: String, title: String?, podcastUuid: String?, feedUrl: String?, mediaUrl: String?, publishedMs: Int64?) {
            self.uuid = uuid
            self.title = title
            self.podcastUuid = podcastUuid
            self.feedUrl = feedUrl
            self.mediaUrl = mediaUrl
            self.publishedMs = publishedMs
        }

        init?(json: [String: Any]) {
            guard let uuid = json["u"] as? String, !uuid.isEmpty else { return nil }
            self.uuid = uuid
            self.title = json["t"] as? String
            self.podcastUuid = json["p"] as? String
            self.feedUrl = json["f"] as? String
            self.mediaUrl = json["m"] as? String
            self.publishedMs = (json["d"] as? NSNumber)?.int64Value
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

    // MARK: Entry point

    /// Pull then push, in that order. Reading before publishing is the same lesson the offline
    /// outbox taught: a device that reordered offline holds a list that is newer by timestamp than
    /// anything on the backend, so publishing first would overwrite another device's queue and then
    /// pull back the row it had just replaced.
    ///
    /// Never throws. The queue sync is an addition to the sync cycle, never a precondition for it.
    public func sync() {
        guard supabase.isLoggedIn() else { return }
        pullBlocking()
        pushIfChangedBlocking()
    }

    /// Push only, for the queue's own change trigger. Cheap when nothing changed: the signature
    /// check short circuits before any network work.
    public func pushIfChanged() {
        #if os(watchOS)
        // The Watch app compiles PlaybackQueue and so reaches this trigger, but its queue is a
        // projection of the phone's and can be a partial standalone list, so it must never publish.
        // The signature rule already blocks it, since the Watch never pulls and therefore never has
        // a signature, but that is an accident of wiring rather than an intention. This is explicit.
        return
        #else
        guard supabase.isLoggedIn() else { return }
        workQueue.async { [weak self] in
            self?.pushIfChangedBlocking()
        }
        #endif
    }

    // MARK: Pull

    private func pullBlocking() {
        do {
            let rows = try supabase.select(table: Self.table, query: "select=episodes,updated_at_ms&limit=1")
            guard let row = rows.first else {
                // No row at all. Asking and being told there is nothing is itself a completed
                // reconcile, and it is the one state it is safe to publish from, so record an empty
                // signature. Without this the first row can never be created: the push waits for a
                // reconcile that can never happen against an empty table. Only when no signature
                // exists yet, so a device whose row was deleted keeps its own and republishes on its
                // next local change rather than immediately.
                if readSignature() == nil {
                    writeSignature([])
                }
                return
            }

            let remoteTs = (row["updated_at_ms"] as? NSNumber)?.int64Value ?? 0

            // The pull always runs before the push, so without this an unpublished local edit would
            // be discarded simply because of that ordering, not because the remote was newer. The
            // stamp is only set while this device is genuinely ahead of the backend and is cleared
            // the moment it catches up, so it cannot block a legitimate remote update.
            //
            // A signature must already exist for the stamp to count. A device that has never
            // reconciled has to read first no matter how recently its queue changed, otherwise a
            // queue built locally before the first pull would make that device refuse the backend's
            // queue forever.
            if readSignature() != nil, let localChangeMs = readLocalChangeMs(), remoteTs > 0, localChangeMs > remoteTs {
                FileLog.shared.addMessage("PodHopper up next: holding a newer unpublished local queue, skipping this remote copy")
                return
            }

            let raw = (row["episodes"] as? [[String: Any]]) ?? []
            let entries = raw.compactMap { Entry(json: $0) }
            applyRemoteQueue(entries)
        } catch {
            FileLog.shared.addMessage("PodHopper up next pull failed: \(error)")
        }
    }

    // MARK: Apply

    /// Applies a remote queue to this device, preserving the episode playing right now and holding
    /// entries this device cannot resolve.
    private func applyRemoteQueue(_ remoteEntries: [Entry]) {
        guard let playback = ServerConfig.shared.playbackDelegate else { return }

        let localEpisodes = playback.allEpisodesInQueue(includeNowPlaying: true)
        let localUuids = localEpisodes.map { $0.uuid }

        // Never displace the episode playing right now. If the incoming head is a different
        // episode, the playing one stays at the head and the remote order applies behind it.
        let entries = preservePlayingEpisode(remoteEntries, playback: playback)

        // Identical lists mean there is nothing to do, but the signature still has to be recorded:
        // this device has now reconciled with the backend, which is what allows it to push later.
        if entries.map({ $0.uuid }) == localUuids {
            writeSignature(localUuids)
            writeHeld([])
            return
        }

        dataManager.snapshotUpNext()

        let episodePlayingBefore = playback.currentEpisode()

        var resolvedUuids = [String]()
        var held = [HeldEntry]()

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
                continue
            }

            // This device has not seen the episode yet, most likely because its feed has not
            // refreshed here. Hold it verbatim at its original index rather than dropping it: the
            // next push re-inserts it, so advancing an episode in the car cannot silently delete
            // entries from the phone. It resolves on its own once a refresh brings the episode in.
            held.append(HeldEntry(index: index, entry: entry))
        }

        dataManager.deleteAllUpNextEpisodesNotIn(uuids: resolvedUuids)

        if !held.isEmpty {
            FileLog.shared.addMessage("PodHopper up next: applied \(resolvedUuids.count) entries, holding \(held.count) this device cannot resolve yet")
        }

        writeHeld(held)
        // The signature records what this device's queue now is, so an unchanged queue produces no
        // push and an applied queue cannot echo back.
        writeSignature(resolvedUuids)

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

    /// Moves the episode playing right now to the head of the incoming list. Adapted from the
    /// Pocket Casts era addPlayingEpisode. Only applies while actually playing: a paused episode is
    /// not protected, matching the position sync's own currently-playing rule.
    private func preservePlayingEpisode(_ entries: [Entry], playback: ServerPlaybackDelegate) -> [Entry] {
        guard playback.playing(), let playing = playback.currentEpisode() else { return entries }
        if entries.first?.uuid == playing.uuid { return entries }

        var list = entries.filter { $0.uuid != playing.uuid }
        list.insert(entry(for: playing), at: 0)
        return list
    }

    // MARK: Push

    private func pushIfChangedBlocking() {
        guard let playback = ServerConfig.shared.playbackDelegate else { return }

        let localEpisodes = playback.allEpisodesInQueue(includeNowPlaying: true)
        let localUuids = localEpisodes.map { $0.uuid }

        // No signature means this device has never reconciled with the backend, so it must read
        // before it writes. This is what stops a fresh install, or a queue that has not finished
        // loading at app start, from publishing an empty list over the user's real queue.
        guard let signature = readSignature() else { return }

        // Nothing changed since the last reconcile, so there is nothing to publish. This also makes
        // an echo impossible: a queue that was just applied equals its own signature.
        //
        // The stamp is cleared here as well as on success. An edit that is later undone leaves this
        // device level with the backend while a stamp is still recorded, and without this clear that
        // stamp would sit set forever and silently refuse every remote queue from then on.
        if signature == localUuids {
            clearLocalChangeMs()
            return
        }

        var entries = localEpisodes.map { entry(for: $0) }

        // Re-insert entries this device could not resolve, at the positions they arrived at, so a
        // push from here cannot delete them from the devices that can resolve them.
        for heldEntry in readHeld().sorted(by: { $0.index < $1.index }) {
            if entries.contains(where: { $0.uuid == heldEntry.entry.uuid }) { continue }
            let index = min(max(heldEntry.index, 0), entries.count)
            entries.insert(heldEntry.entry, at: index)
        }

        do {
            guard let userId = try supabase.getUserId() else { return }
            let row: [String: Any] = [
                "user_id": userId,
                "episodes": entries.map { $0.json },
                "device_id": PodHopperPositionSync.shared.deviceInstallId(),
                "device_name": PodHopperPositionSync.shared.deviceDisplayName(),
                "updated_at_ms": nowMs(),
            ]
            try supabase.upsert(table: Self.table, onConflictColumns: "user_id", rows: [row])
            writeSignature(localUuids)
            // Published, so this device is no longer ahead of the backend.
            clearLocalChangeMs()
        } catch {
            // Left unsignatured on purpose: the next sync sees the list still differs and retries.
            FileLog.shared.addMessage("PodHopper up next push failed, will retry on the next change: \(error)")
        }
    }

    // MARK: Entry building

    private func entry(for episode: BaseEpisode) -> Entry {
        let podcastUuid = episode.parentIdentifier()
        // Populated wherever it is known, unlike Android, which leaves it null for local episodes.
        // PodHopper resolves podcasts by feed url, so an entry carrying one can be resolved by a
        // device that has never seen that podcast, which turns a held entry into a recoverable one.
        let feedUrl = dataManager.findPodcast(uuid: podcastUuid, includeUnsubscribed: true)?.podcastUrl
        let publishedMs = episode.publishedDate.map { Int64($0.timeIntervalSince1970 * 1000) }

        return Entry(
            uuid: episode.uuid,
            title: episode.displayableTitle(),
            podcastUuid: podcastUuid,
            feedUrl: feedUrl,
            mediaUrl: episode.downloadUrl,
            publishedMs: publishedMs
        )
    }

    // MARK: Local state

    /// Records that this device's queue just changed locally, so a pull arriving before the change
    /// is published cannot discard it.
    ///
    /// Called from the queue's own change trigger rather than from the push, because the push is
    /// debounced by several seconds and an edit followed by the app being backgrounded would
    /// otherwise never be stamped at all.
    ///
    /// This is deliberately not called from the apply path, and does not need to be: applying a
    /// remote queue writes its rows straight through DataManager rather than through PlaybackQueue's
    /// mutation methods, so it never reaches this trigger. If the apply is ever rewritten to go
    /// through PlaybackQueue, it must exclude itself here, or the device will claim to be ahead of
    /// the backend the instant it accepts an update and start refusing the queues it just took.
    ///
    /// The comparison this feeds comes down to one device's clock against another's, which is the
    /// same assumption the position sync already makes and is fine for network-synced devices.
    public func noteLocalChange() {
        #if os(watchOS)
        // The Watch never pulls or pushes, so a stamp written here would never be read.
        return
        #else
        defaults.set(NSNumber(value: nowMs()), forKey: Self.localChangeKey)
        #endif
    }

    private func readLocalChangeMs() -> Int64? {
        guard let value = defaults.object(forKey: Self.localChangeKey) as? NSNumber else { return nil }
        return value.int64Value
    }

    private func clearLocalChangeMs() {
        defaults.removeObject(forKey: Self.localChangeKey)
    }

    /// The uuid list this device last reconciled with the backend. Absent until the first pull.
    private func readSignature() -> [String]? {
        defaults.array(forKey: Self.signatureKey) as? [String]
    }

    private func writeSignature(_ uuids: [String]) {
        defaults.set(uuids, forKey: Self.signatureKey)
    }

    struct HeldEntry {
        let index: Int
        let entry: Entry
    }

    private func readHeld() -> [HeldEntry] {
        guard let data = defaults.data(forKey: Self.heldKey),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return raw.compactMap { item in
            guard let index = (item["i"] as? NSNumber)?.intValue,
                  let entryJson = item["e"] as? [String: Any],
                  let entry = Entry(json: entryJson) else { return nil }
            return HeldEntry(index: index, entry: entry)
        }
    }

    private func writeHeld(_ held: [HeldEntry]) {
        if held.isEmpty {
            defaults.removeObject(forKey: Self.heldKey)
            return
        }
        let raw = held.map { ["i": NSNumber(value: $0.index), "e": $0.entry.json] }
        if let data = try? JSONSerialization.data(withJSONObject: raw) {
            defaults.set(data, forKey: Self.heldKey)
        }
    }

    /// Clears the signature and held entries so the next sign in reads before it writes. Does not
    /// touch the queue itself.
    public func clearLocalSyncState() {
        defaults.removeObject(forKey: Self.signatureKey)
        defaults.removeObject(forKey: Self.heldKey)
        defaults.removeObject(forKey: Self.localChangeKey)
    }

    private func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private static let table = "up_next_queue"
    private static let signatureKey = "up_next_signature"
    private static let heldKey = "up_next_held"
    private static let localChangeKey = "up_next_local_change_ms"
}
