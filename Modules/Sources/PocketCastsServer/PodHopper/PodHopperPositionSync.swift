import Combine
import Foundation
import PocketCastsDataModel
import PocketCastsUtils
#if os(watchOS)
import WatchKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The playback effects the position sync needs from its host (the phone app or the Watch app).
/// Everything else (the network, the cursor, parked rows, and the staleness guard) lives in the
/// engine; these are the parts that must go through the host's real playback machinery so the player
/// and UI stay consistent. Implementations should bump the relevant modified timestamp when they
/// change played-up-to or playing status so the rest of the data model stays consistent.
public protocol PodHopperPositionSyncDelegate: AnyObject {
    /// Apply a synced position. Must set playedUpTo and bump playedUpToModified.
    func updatePlayedUpTo(episode: BaseEpisode, positionSec: Double)
    /// Move a not-played episode to in-progress so status and position stay consistent. Must bump
    /// playingStatusModified.
    func markInProgress(episode: BaseEpisode)
    /// A real local mark-as-played: removes from Up Next and auto-archives per the podcast settings.
    func markAsPlayed(episode: BaseEpisode)
    /// Switch the player to this episode, paused at its synced position, with the host's own
    /// do-not-interrupt guards.
    func adoptEpisodeIntoPlayer(episode: BaseEpisode)
    /// The uuid of the episode that is actively playing right now, or nil if nothing is playing.
    /// Used to never overwrite the episode currently playing on this device.
    func currentlyPlayingEpisodeUuid() -> String?
    /// The current episode and its live position/duration in milliseconds, for the shutdown push.
    func currentEpisodeForPush() -> (episode: BaseEpisode, positionMs: Int, durationMs: Int)?
    /// Whether the user has left the auto-switch-to-current-episode setting on.
    func autoSwitchToCurrentEpisodeEnabled() -> Bool
}

/// Syncs playback position and completion across devices (phone, car, watch) through Supabase. A
/// faithful port of the Android `PodHopperPositionSync`.
///
/// Two pulls (playback service start and app foreground) and four pushes (a periodic sample while
/// playing, an immediate push on pause, an immediate push on shutdown, and an explicit completion
/// push) keep surfaces in step. Completion is an explicit fact: a finish writes completed=true, and
/// the receiver runs a real local mark-as-played, so finishing on one device removes the episode on
/// the other.
///
/// Conflict resolution is freshest-writer-wins on a server-stamped timestamp. There is one
/// playback_state row per episode, overwritten by whoever played it last, and updated_at_ms is
/// stamped by Supabase, so a row from another device is the latest state by the one clock every
/// device shares. The only thing a remote row will not overwrite is the episode actively playing
/// here right now. The pull drains every page in one open, advances its cursor only after a page is
/// accounted for, and parks rows for episodes not in the local database yet so a position is never
/// lost because a feed had not refreshed. A fresh sign-in starts watching from the database's newest
/// timestamp in server time.
///
/// The engine is in the shared module so the phone, CarPlay (same process), and the Watch app can
/// drive it; the host supplies the playback effects through `delegate`.
public final class PodHopperPositionSync {

    public static let shared = PodHopperPositionSync()

    public weak var delegate: PodHopperPositionSyncDelegate?

    private let supabase: PodHopperSupabaseClient
    private let feedManager: PodHopperFeedManager
    private let dataManager: DataManager
    private let defaults: UserDefaults

    private let workQueue = DispatchQueue(label: "au.com.podhopper.positionsync", qos: .utility)
    private let stateLock = NSLock()
    private var _lastPushAttemptMs: Int64 = 0
    private var _lastReconcileMs: Int64 = 0
    private var _applyingUuids = Set<String>()
    private var cachedInstallId: String?

    private var cancellables = Set<AnyCancellable>()

    public init(
        supabase: PodHopperSupabaseClient = .shared,
        feedManager: PodHopperFeedManager = .shared,
        dataManager: DataManager = .sharedManager,
        defaults: UserDefaults = UserDefaults(suiteName: PodHopperPositionSync.suiteName) ?? .standard
    ) {
        self.supabase = supabase
        self.feedManager = feedManager
        self.dataManager = dataManager
        self.defaults = defaults
        observeSignIn()
    }

    /// True while the sync is applying a remote change to this episode. Push hooks skip when true so
    /// a mark-as-played the sync just applied is not echoed back as a completion push.
    public func isApplyingRemote(uuid: String) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _applyingUuids.contains(uuid)
    }

    /// Pulls the latest cross-device positions the instant sign-in completes. Startup value dropped,
    /// so only a real transition into the signed-in state triggers a pull.
    private func observeSignIn() {
        supabase.loginState
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] loggedIn in
                if loggedIn {
                    self?.pullLatestPositions()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: Push

    /// Push a single episode position. Throttled to one push every [minPushIntervalMs] unless
    /// immediate (pause and shutdown). The completed column is deliberately omitted so a position
    /// sample can never un-complete an episode another flow just finished.
    public func pushPosition(episode: BaseEpisode, positionMs: Int, durationMs: Int, immediate: Bool) {
        if !supabase.isLoggedIn() {
            return
        }
        if positionMs <= 0 {
            return
        }
        let now = nowMs()
        if !immediate {
            stateLock.lock()
            let throttled = now - _lastPushAttemptMs < Self.minPushIntervalMs
            if throttled {
                stateLock.unlock()
                return
            }
            _lastPushAttemptMs = now
            stateLock.unlock()
        } else {
            stateLock.lock(); _lastPushAttemptMs = now; stateLock.unlock()
        }

        let episodeKey = episode.uuid
        let episodeUrl = episode.downloadUrl
        let positionSec = positionMs / 1000
        let totalSec = durationMs / 1000
        let podcastUuid = (episode as? Episode)?.podcastUuid

        workQueue.async {
            do {
                guard let userId = try self.supabase.getUserId() else { return }
                let feedUrl = podcastUuid.flatMap { self.dataManager.findPodcast(uuid: $0, includeUnsubscribed: true)?.podcastUrl }
                let row: [String: Any] = [
                    "user_id": userId,
                    "episode_key": episodeKey,
                    "episode_url": episodeUrl ?? NSNull(),
                    "position_sec": positionSec,
                    "total_sec": totalSec,
                    "feed_url": feedUrl ?? NSNull(),
                    "device_id": self.installId(),
                    "device_name": self.deviceName(),
                    "updated_at_ms": now,
                ]
                try self.supabase.upsert(table: Self.table, onConflictColumns: "user_id,episode_key", rows: [row])
            } catch {
                FileLog.shared.addMessage("PodHopper position push failed, will retry next cycle: \(error)")
            }
        }
    }

    /// Push the current episode's live position. Used for the shutdown push, where the caller does
    /// not have the position to hand.
    public func pushCurrentPosition(immediate: Bool) {
        if !supabase.isLoggedIn() {
            return
        }
        guard let snapshot = delegate?.currentEpisodeForPush() else {
            return
        }
        pushPosition(episode: snapshot.episode, positionMs: snapshot.positionMs, durationMs: snapshot.durationMs, immediate: immediate)
    }

    /// Push an explicit completion. Called on natural finish and manual mark-as-played. Skipped when
    /// this completion is itself the result of a remote apply (the echo guard).
    public func pushCompletion(episode: BaseEpisode) {
        if !supabase.isLoggedIn() {
            return
        }
        if isApplyingRemote(uuid: episode.uuid) {
            return
        }
        // iOS stores duration and playedUpTo in seconds (Android used milliseconds).
        let totalSec = Int(episode.duration > 0 ? episode.duration : episode.playedUpTo)
        let episodeKey = episode.uuid
        let episodeUrl = episode.downloadUrl
        let podcastUuid = (episode as? Episode)?.podcastUuid
        let now = nowMs()

        workQueue.async {
            do {
                guard let userId = try self.supabase.getUserId() else { return }
                let feedUrl = podcastUuid.flatMap { self.dataManager.findPodcast(uuid: $0, includeUnsubscribed: true)?.podcastUrl }
                let row: [String: Any] = [
                    "user_id": userId,
                    "episode_key": episodeKey,
                    "episode_url": episodeUrl ?? NSNull(),
                    "position_sec": totalSec,
                    "total_sec": totalSec,
                    "completed": true,
                    "feed_url": feedUrl ?? NSNull(),
                    "device_id": self.installId(),
                    "device_name": self.deviceName(),
                    "updated_at_ms": now,
                ]
                try self.supabase.upsert(table: Self.table, onConflictColumns: "user_id,episode_key", rows: [row])
            } catch {
                FileLog.shared.addMessage("PodHopper completion push failed, will retry on next finish: \(error)")
            }
        }
    }

    // MARK: Pull

    /// Pull positions and completions newer than our cursor written by other devices, and apply them.
    /// Drains every page so one open fully catches up. When [adoptCurrentEpisode] is set (foreground
    /// and service-start pulls only), also switches the player to the most recent in-progress episode
    /// from another device, subject to the user's setting and the host's interrupt guards.
    public func pullLatestPositions(adoptCurrentEpisode: Bool = false) {
        if !supabase.isLoggedIn() {
            return
        }
        workQueue.async {
            do {
                let installId = self.installId()
                var cursor = try self.cursorOrStartFresh()

                while true {
                    let query = "select=episode_key,position_sec,total_sec,completed,updated_at_ms,device_id,feed_url"
                        + "&updated_at_ms=gt.\(cursor)"
                        + "&device_id=neq.\(installId)"
                        + "&order=updated_at_ms.asc"
                        + "&limit=\(PodHopperConfig.pullPageLimit)"
                    let rows = try self.supabase.select(table: Self.table, query: query)
                    let count = rows.count
                    if count == 0 {
                        break
                    }
                    let result = self.applyRows(rows)
                    if result.maxTs > cursor {
                        cursor = result.maxTs
                        self.setCursor(cursor)
                    } else {
                        break
                    }
                    if count < PodHopperConfig.pullPageLimit {
                        break
                    }
                }

                self.retryParkedRows()

                // Resume the now-playing window from the freshest cross-device state. This uses a
                // direct "most recent in-progress across other devices" query, not the cursor page,
                // so it finds a position written before the cursor (the common cross-device resume
                // case the page pull can never see). Guarded so it never changes what is playing
                // while this device is actively playing.
                if adoptCurrentEpisode, self.delegate?.currentlyPlayingEpisodeUuid() == nil {
                    try self.adoptLatestForResume()
                }
            } catch {
                FileLog.shared.addMessage("PodHopper position pull failed: \(error)")
            }
        }
    }

    /// Reconcile the now-playing window with the freshest cross-device state: refresh saved positions
    /// and, when this device is not actively playing, switch the current episode to the most recently
    /// played one from another device and apply its synced position. Throttled by [reconcileMinIntervalMs]
    /// so a burst of triggers (foreground immediately followed by the timer, for instance) collapses
    /// into one pull. Called by every "the user is engaging now" trigger: app foreground and the 30s
    /// in-app timer.
    public func reconcileNowPlaying() {
        if !supabase.isLoggedIn() {
            return
        }
        let now = nowMs()
        stateLock.lock()
        let throttled = now - _lastReconcileMs < Self.reconcileMinIntervalMs
        if throttled {
            stateLock.unlock()
            return
        }
        _lastReconcileMs = now
        stateLock.unlock()
        pullLatestPositions(adoptCurrentEpisode: true)
    }

    private struct AdoptCandidate {
        let episodeKey: String
        let feedUrl: String?
        let updatedAtMs: Int64
    }

    private struct ApplyResult {
        let maxTs: Int64
    }

    /// Finds the most recently played in-progress episode written by another device and, when the
    /// auto-switch setting is on and that row is newer than this device's own latest write, applies
    /// its synced position to the local episode and switches the player to it (paused). This is a
    /// direct "freshest across other devices" query, not the cursor page, so it resumes a position
    /// written before the cursor. Mirrors the Android adoptLatestForResume + applyRemotePositionBeforePlay
    /// resume path. Throws on a network error so the enclosing pull logs and retries. Blocking; runs
    /// on the calling background queue.
    private func adoptLatestForResume() throws {
        guard delegate?.autoSwitchToCurrentEpisodeEnabled() == true else {
            return
        }
        let installId = self.installId()
        let query = "select=episode_key,feed_url,position_sec,total_sec,completed,updated_at_ms"
            + "&device_id=neq.\(installId)"
            + "&order=updated_at_ms.desc"
            + "&limit=\(Self.adoptScanLimit)"
        let rows = try supabase.select(table: Self.table, query: query)
        guard let candidate = latestInProgressFrom(rows) else {
            return
        }
        // Core guard, in server time: only switch to another device's episode when that row is newer
        // than this device's own most recent write. Both timestamps are stamped by Supabase, so this
        // compares one clock to itself, never two device clocks.
        let myLatest = try latestServerTs(onlyThisDevice: true)
        if candidate.updatedAtMs <= myLatest {
            return
        }
        var episode = dataManager.findEpisode(uuid: candidate.episodeKey)
        if episode == nil, let feedUrl = candidate.feedUrl, !feedUrl.isEmpty {
            _ = feedManager.addFeedUrlAsUnsubscribed(feedUrl)
            episode = dataManager.findEpisode(uuid: candidate.episodeKey)
        }
        guard let target = episode else {
            return
        }
        // Apply the synced position to the local episode first, so when the player loads the adopted
        // episode it prepares paused at the right spot rather than at the stale local position.
        _ = applyRemotePositionBeforePlay(episode: target)
        delegate?.adoptEpisodeIntoPlayer(episode: target)
    }

    /// The most recently played still-in-progress episode in a desc-ordered page of rows. Completions
    /// are skipped so a finished episode never becomes a now-playing.
    private func latestInProgressFrom(_ rows: [[String: Any]]) -> AdoptCandidate? {
        for row in rows {
            guard let episodeKey = row["episode_key"] as? String, !episodeKey.isEmpty else {
                continue
            }
            let positionSec = (row["position_sec"] as? NSNumber)?.intValue ?? -1
            let totalSec = (row["total_sec"] as? NSNumber)?.intValue ?? 0
            let completed = (row["completed"] as? Bool) ?? ((row["completed"] as? NSNumber)?.boolValue ?? false)
            if Self.isCompletionRow(positionSec: positionSec, totalSec: totalSec, completed: completed) {
                continue
            }
            let feedUrl = (row["feed_url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return AdoptCandidate(episodeKey: episodeKey, feedUrl: feedUrl, updatedAtMs: (row["updated_at_ms"] as? NSNumber)?.int64Value ?? 0)
        }
        return nil
    }

    /// Pulls this episode's latest cross-device position and applies it BEFORE playback reads the
    /// resume point, so a play starts from the synced position. Bounded by [playPullTimeoutMs] so a
    /// slow network cannot hang playback. Blocking; call off the main thread from the play flow.
    public func applyRemotePositionBeforePlay(episode: BaseEpisode) -> PlayPullResult {
        if !supabase.isLoggedIn() {
            return .none
        }
        var result: PlayPullResult = .failed
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let installId = self.installId()
                let query = "select=position_sec,total_sec,updated_at_ms,device_id"
                    + "&episode_key=eq.\(episode.uuid)"
                    + "&device_id=neq.\(installId)"
                    + "&order=updated_at_ms.desc"
                    + "&limit=1"
                let rows = try self.supabase.select(table: Self.table, query: query)
                if rows.isEmpty {
                    result = .none
                } else {
                    let positionSec = (rows[0]["position_sec"] as? NSNumber)?.intValue ?? -1
                    if positionSec < 0 {
                        result = .none
                    } else {
                        self.delegate?.updatePlayedUpTo(episode: episode, positionSec: Double(positionSec))
                        result = .applied
                    }
                }
            } catch {
                result = .failed
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + .milliseconds(Int(Self.playPullTimeoutMs))) == .timedOut {
            FileLog.shared.addMessage("PodHopper play-pull timed out, playing from local position")
            return .failed
        }
        return result
    }

    public enum PlayPullResult {
        case applied
        case none
        case failed
    }

    /// Async variant for the main-thread play path. Runs the bounded at-play pull on a background
    /// queue and then calls [completion] on the main thread, so playback can start from the synced
    /// position without ever blocking the main thread. The completion is always called exactly once,
    /// including when signed out or when the pull times out, so the play flow never stalls.
    public func applyRemotePositionBeforePlay(episode: BaseEpisode, completion: @escaping () -> Void) {
        if !supabase.isLoggedIn() {
            DispatchQueue.main.async {
                completion()
            }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.applyRemotePositionBeforePlay(episode: episode)
            DispatchQueue.main.async {
                completion()
            }
        }
    }

    // MARK: Apply

    /// Applies every row in a page, parking those whose episode is not local yet. Returns the highest
    /// updated_at_ms seen so the caller can advance the cursor past the whole page.
    private func applyRows(_ rows: [[String: Any]]) -> ApplyResult {
        var maxTs: Int64 = 0
        for row in rows {
            let updatedAtMs = (row["updated_at_ms"] as? NSNumber)?.int64Value ?? 0
            if updatedAtMs > maxTs {
                maxTs = updatedAtMs
            }
            guard let episodeKey = row["episode_key"] as? String, !episodeKey.isEmpty else {
                continue
            }
            let positionSec = (row["position_sec"] as? NSNumber)?.intValue ?? -1
            let totalSec = (row["total_sec"] as? NSNumber)?.intValue ?? 0
            let completed = (row["completed"] as? Bool) ?? ((row["completed"] as? NSNumber)?.boolValue ?? false)
            applyOrPark(episodeKey: episodeKey, positionSec: positionSec, totalSec: totalSec, completed: completed, remoteTs: updatedAtMs)
        }
        return ApplyResult(maxTs: maxTs)
    }

    private func applyOrPark(episodeKey: String, positionSec: Int, totalSec: Int, completed: Bool, remoteTs: Int64) {
        guard let episode = dataManager.findEpisode(uuid: episodeKey) else {
            parkRow(episodeKey: episodeKey, positionSec: positionSec, totalSec: totalSec, completed: completed, remoteTs: remoteTs)
            return
        }
        applyOne(episode: episode, positionSec: positionSec, totalSec: totalSec, completed: completed)
    }

    private func applyOne(episode: Episode, positionSec: Int, totalSec: Int, completed: Bool) {
        let isCurrentlyPlayingThis = delegate?.currentlyPlayingEpisodeUuid() == episode.uuid
        let playingStatusIsNotPlayed = episode.playingStatus == PlayingStatus.notPlayed.rawValue

        let decision = Self.decideApply(
            isCurrentlyPlayingThisEpisode: isCurrentlyPlayingThis,
            positionSec: positionSec,
            totalSec: totalSec,
            completed: completed,
            playingStatusIsNotPlayed: playingStatusIsNotPlayed
        )

        switch decision {
        case .skip:
            return
        case .complete:
            addApplying(episode.uuid)
            delegate?.markAsPlayed(episode: episode)
            removeApplying(episode.uuid)
        case .setPosition(let sec, let markInProgress):
            delegate?.updatePlayedUpTo(episode: episode, positionSec: sec)
            if markInProgress {
                delegate?.markInProgress(episode: episode)
            }
        }
    }

    /// The pure apply decision. Freshest writer wins: the row came from another device's write to the
    /// episode's single shared row, so it is the latest state by the server's own clock; the one thing
    /// it will not stomp is the episode actively playing on this device right now. Then completion
    /// versus position. Tested directly with no database or player.
    static func decideApply(
        isCurrentlyPlayingThisEpisode: Bool,
        positionSec: Int,
        totalSec: Int,
        completed: Bool,
        playingStatusIsNotPlayed: Bool
    ) -> ApplyDecision {
        if isCurrentlyPlayingThisEpisode {
            return .skip
        }
        if isCompletionRow(positionSec: positionSec, totalSec: totalSec, completed: completed) {
            return .complete
        }
        if positionSec >= 0 {
            return .setPosition(Double(positionSec), markInProgress: playingStatusIsNotPlayed)
        }
        return .skip
    }

    /// A completion is an explicit completed flag, or a position at or past the end.
    static func isCompletionRow(positionSec: Int, totalSec: Int, completed: Bool) -> Bool {
        completed || (totalSec > 0 && positionSec >= totalSec)
    }

    enum ApplyDecision: Equatable {
        case skip
        case complete
        case setPosition(Double, markInProgress: Bool)
    }

    // MARK: Parked rows

    private func parkRow(episodeKey: String, positionSec: Int, totalSec: Int, completed: Bool, remoteTs: Int64) {
        var parked = readParked()
        parked[episodeKey] = ["p": positionSec, "t": totalSec, "c": completed, "u": remoteTs]
        if parked.count > Self.maxParked {
            let oldestFirst = parked.sorted { lhs, rhs in
                ((lhs.value["u"] as? NSNumber)?.int64Value ?? 0) < ((rhs.value["u"] as? NSNumber)?.int64Value ?? 0)
            }
            let dropCount = parked.count - Self.maxParked
            for entry in oldestFirst.prefix(dropCount) {
                parked.removeValue(forKey: entry.key)
            }
        }
        writeParked(parked)
    }

    private func retryParkedRows() {
        var parked = readParked()
        if parked.isEmpty {
            return
        }
        var changed = false
        for (episodeKey, entry) in parked {
            guard let episode = dataManager.findEpisode(uuid: episodeKey) else { continue }
            applyOne(
                episode: episode,
                positionSec: (entry["p"] as? NSNumber)?.intValue ?? -1,
                totalSec: (entry["t"] as? NSNumber)?.intValue ?? 0,
                completed: (entry["c"] as? Bool) ?? ((entry["c"] as? NSNumber)?.boolValue ?? false)
            )
            parked.removeValue(forKey: episodeKey)
            changed = true
        }
        if changed {
            writeParked(parked)
        }
    }

    private func readParked() -> [String: [String: Any]] {
        guard let data = defaults.data(forKey: Self.parkedKey) else { return [:] }
        let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]]
        return parsed ?? [:]
    }

    private func writeParked(_ parked: [String: [String: Any]]) {
        if let data = try? JSONSerialization.data(withJSONObject: parked) {
            defaults.set(data, forKey: Self.parkedKey)
        }
    }

    // MARK: Cursor and install id

    private func cursorOrStartFresh() throws -> Int64 {
        let stored = defaults.object(forKey: Self.lastPullMsKey) as? NSNumber
        if let stored, stored.int64Value != Self.firstSyncSentinel {
            return stored.int64Value
        }
        // First sync on this device: seed from the database's own newest timestamp, which is server
        // time, the one clock every device shares, rather than this device's clock. A device whose
        // clock runs ahead would otherwise seed the cursor past rows it has never seen and skip them
        // forever. We begin watching from now in server time; we do not replay the whole history.
        let seed = try latestServerTs(onlyThisDevice: false)
        setCursor(seed)
        return seed
    }

    private func setCursor(_ value: Int64) {
        defaults.set(NSNumber(value: value), forKey: Self.lastPullMsKey)
    }

    /// The newest updated_at_ms the database holds for this user, optionally limited to this device's
    /// own writes. These timestamps are stamped by Supabase, so they are the one clock every device
    /// shares. Returns 0 when there is no matching row. Blocking; call from a background queue.
    private func latestServerTs(onlyThisDevice: Bool) throws -> Int64 {
        let deviceClause = onlyThisDevice ? "&device_id=eq.\(installId())" : ""
        let query = "select=updated_at_ms" + deviceClause + "&order=updated_at_ms.desc&limit=1"
        let rows = try supabase.select(table: Self.table, query: query)
        guard let first = rows.first else {
            return 0
        }
        return (first["updated_at_ms"] as? NSNumber)?.int64Value ?? 0
    }

    private func installId() -> String {
        stateLock.lock()
        if let cached = cachedInstallId {
            stateLock.unlock()
            return cached
        }
        stateLock.unlock()

        if let existing = defaults.string(forKey: Self.installIdKey) {
            stateLock.lock(); cachedInstallId = existing; stateLock.unlock()
            return existing
        }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: Self.installIdKey)
        stateLock.lock(); cachedInstallId = generated; stateLock.unlock()
        return generated
    }

    /// Resets this device's position sync bookkeeping so a future account starts clean. Clears the
    /// pull cursor and parked rows, sending the cursor back to the first-sync sentinel. The install
    /// id is kept, since it identifies the device, not the account. Does not touch any episode,
    /// podcast, or playback data.
    public func clearLocalSyncState() {
        defaults.removeObject(forKey: Self.lastPullMsKey)
        defaults.removeObject(forKey: Self.parkedKey)
    }

    // MARK: Applying-uuid set

    private func addApplying(_ uuid: String) {
        stateLock.lock(); _applyingUuids.insert(uuid); stateLock.unlock()
    }

    private func removeApplying(_ uuid: String) {
        stateLock.lock(); _applyingUuids.remove(uuid); stateLock.unlock()
    }

    // MARK: Helpers

    private func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func deviceName() -> String {
        #if os(watchOS)
        return WKInterfaceDevice.current().model
        #elseif canImport(UIKit)
        return UIDevice.current.model
        #else
        return "Apple Device"
        #endif
    }

    // MARK: Constants

    public static let suiteName = "podhopper_position_sync"
    private static let table = "playback_state"
    private static let installIdKey = "install_id"
    private static let lastPullMsKey = "last_pull_ms"
    private static let parkedKey = "parked_rows"
    private static let minPushIntervalMs: Int64 = 4000
    private static let playPullTimeoutMs: Int64 = 5000
    private static let reconcileMinIntervalMs: Int64 = 5000
    private static let adoptScanLimit = 10
    private static let firstSyncSentinel: Int64 = -1
    private static let maxParked = 500
}
