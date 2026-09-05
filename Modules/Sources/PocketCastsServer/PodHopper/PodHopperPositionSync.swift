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
    /// A real local mark-as-unplayed: resets played status and position and unarchives. Used when a
    /// remote row regresses an episode this device had finished. Must bump playingStatusModified.
    func markAsUnplayed(episode: BaseEpisode)
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
    /// Per-episode timestamps of recent sync applies, for the circuit breaker.
    private var _applyHistory = [String: [Int64]]()
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
            // Built from local data only, deliberately without the user id. Resolving the user id
            // refreshes the auth session over the network, so it throws while offline and returns
            // nothing at all after a process restart, which is exactly when this row needs saving.
            // The id is stamped at send time, when the device is by definition online.
            let feedUrl = podcastUuid.flatMap { self.dataManager.findPodcast(uuid: $0, includeUnsubscribed: true)?.podcastUrl }
            let row: [String: Any] = [
                "episode_key": episodeKey,
                "episode_url": episodeUrl ?? NSNull(),
                "position_sec": positionSec,
                "total_sec": totalSec,
                "feed_url": feedUrl ?? NSNull(),
                "device_id": self.installId(),
                "device_name": self.deviceName(),
                "updated_at_ms": now,
            ]
            do {
                guard let userId = try self.supabase.getUserId() else {
                    self.enqueuePending([row])
                    return
                }
                var wire = row
                wire["user_id"] = userId
                try self.supabase.upsert(table: Self.table, onConflictColumns: "user_id,episode_key", rows: [wire])
            } catch {
                self.enqueuePending([row])
                FileLog.shared.addMessage("PodHopper position push failed, queued for retry: \(error)")
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

    /// Push an explicit completion. Thin wrapper kept for the single-episode callers.
    public func pushCompletion(episode: BaseEpisode) {
        pushPlayedState(episodes: [episode], completed: true)
    }

    /// Push played state for any number of episodes. Every path that changes played state goes
    /// through here: single mark-played, single un-mark, both bulk paths, and natural completion.
    /// A completed row parks position at the duration and an un-marked row parks it at zero, so a
    /// consumer reading position alone still reads the episode correctly. Rows go up in chunks, and
    /// a failed chunk logs and lets the remaining chunks through rather than abandoning them.
    ///
    /// Skipped per episode when that episode is itself mid-apply from the sync (the echo guard).
    /// This covers un-marks too, because applying a regression calls the host's mark-as-unplayed,
    /// which pushes.
    public func pushPlayedState(episodes: [BaseEpisode], completed: Bool) {
        if !supabase.isLoggedIn() {
            return
        }
        let candidates = episodes.filter { !isApplyingRemote(uuid: $0.uuid) }
        if candidates.isEmpty {
            return
        }

        // Snapshot everything the push needs while still on the calling thread. Episode objects are
        // not safe to read from the work queue.
        // iOS stores duration and playedUpTo in seconds (Android used milliseconds).
        let snapshots: [(key: String, url: String?, totalSec: Int, podcastUuid: String?)] = candidates.map { episode in
            (
                key: episode.uuid,
                url: episode.downloadUrl,
                totalSec: Int(episode.duration > 0 ? episode.duration : episode.playedUpTo),
                podcastUuid: (episode as? Episode)?.podcastUuid
            )
        }
        let now = nowMs()

        workQueue.async {
            let deviceId = self.installId()
            let deviceName = self.deviceName()
            // Built without the user id for the same reason as pushPosition: it is unavailable
            // offline, which is precisely when these rows need to survive.
            let rows: [[String: Any]] = snapshots.map { snapshot in
                let feedUrl = snapshot.podcastUuid.flatMap { self.dataManager.findPodcast(uuid: $0, includeUnsubscribed: true)?.podcastUrl }
                return [
                    "episode_key": snapshot.key,
                    "episode_url": snapshot.url ?? NSNull(),
                    "position_sec": completed ? snapshot.totalSec : 0,
                    "total_sec": snapshot.totalSec,
                    "completed": completed,
                    "feed_url": feedUrl ?? NSNull(),
                    "device_id": deviceId,
                    "device_name": deviceName,
                    "updated_at_ms": now,
                ]
            }
            do {
                guard let userId = try self.supabase.getUserId() else {
                    self.enqueuePending(rows)
                    return
                }
                var start = 0
                while start < rows.count {
                    let end = min(start + Self.pushChunkSize, rows.count)
                    let chunk = Array(rows[start ..< end])
                    do {
                        let wire = chunk.map { row -> [String: Any] in
                            var copy = row
                            copy["user_id"] = userId
                            return copy
                        }
                        try self.supabase.upsert(table: Self.table, onConflictColumns: "user_id,episode_key", rows: wire)
                    } catch {
                        // Only the failed chunk is queued; the remaining chunks still go.
                        self.enqueuePending(chunk)
                        FileLog.shared.addMessage("PodHopper played-state push chunk failed, queued for retry: \(error)")
                    }
                    start = end
                }
            } catch {
                self.enqueuePending(rows)
                FileLog.shared.addMessage("PodHopper played-state push failed, queued for retry: \(error)")
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

                // Walk the completion history. Runs after the delta pull so the cheap incremental
                // path settles first. It has its own error handling, so a reconcile failure does not
                // mask a successful delta pull.
                self.reconcileCompletions()

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

            // Publish anything an earlier push could not send. Deliberately after the pull, never
            // before: a device that acted offline holds queued rows that are newer by timestamp than
            // anything on the backend, so draining first would overwrite another device's state and
            // then pull back the row it had just replaced, finding nothing new. Read before
            // publishing. Outside the catch above so a failed pull does not skip the drain, and
            // self-contained so a drain failure can never stop the sync around it.
            self.drainPendingPushes()

            // The queue and the playback position are the same state: the first entry of the queue
            // is the episode playing. Refreshing them together is what stops a device restoring the
            // right position inside an episode while showing a queue from some earlier cycle. Self
            // contained, so a failure here cannot affect position or completion sync.
            PodHopperUpNextSync.shared.sync()
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
                        // requiredStartingPosition only honors playedUpTo when the episode is in
                        // progress. An episode played only on another device is notPlayed locally, so
                        // mark it in progress here, exactly as the page pull does when it applies a
                        // position, otherwise the resume point is ignored and play starts from zero.
                        if episode.playingStatus == PlayingStatus.notPlayed.rawValue {
                            self.delegate?.markInProgress(episode: episode)
                        }
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

    // MARK: Completions reconcile

    /// Walks the completion history and applies any completion this device has not finished
    /// locally, paging forward on its own cursor which starts from the beginning of time.
    ///
    /// Deliberately NOT filtered by device_id. The shared row records only its most recent writer,
    /// so a device can author a completion row while its own local state stays unfinished, and a
    /// device filter then hides that completion from the one device that needs it, permanently.
    /// Applying an own row is idempotent: episodes already completed here are skipped, and the
    /// staleness guard in the apply path stops a historical row from undoing a newer local change.
    ///
    /// Only completions are replayed from history. Positions are not, because a historical position
    /// row can be older than this device's local progress and would rewind it; live positions belong
    /// to the delta pull. Blocking; runs on the calling background queue.
    private func reconcileCompletions() {
        do {
            var cursor = (defaults.object(forKey: Self.completionsCursorKey) as? NSNumber)?.int64Value ?? 0

            while true {
                let query = "select=episode_key,position_sec,total_sec,updated_at_ms"
                    + "&completed=is.true"
                    + "&updated_at_ms=gt.\(cursor)"
                    + "&order=updated_at_ms.asc"
                    + "&limit=\(PodHopperConfig.pullPageLimit)"
                let rows = try supabase.select(table: Self.table, query: query)
                let count = rows.count
                if count == 0 {
                    break
                }

                var maxTs = cursor
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
                    guard let episode = dataManager.findEpisode(uuid: episodeKey) else {
                        // Same guarantee as the delta pull: an episode whose feed has not refreshed
                        // here yet is parked, not dropped, and applied once it exists.
                        parkRow(episodeKey: episodeKey, positionSec: positionSec, totalSec: totalSec, completed: true, remoteTs: updatedAtMs)
                        continue
                    }
                    if episode.playingStatus != PlayingStatus.completed.rawValue {
                        applyOne(episode: episode, positionSec: positionSec, totalSec: totalSec, completed: true, remoteTs: updatedAtMs)
                    }
                }

                if maxTs > cursor {
                    cursor = maxTs
                    defaults.set(NSNumber(value: cursor), forKey: Self.completionsCursorKey)
                } else {
                    break
                }
                if count < PodHopperConfig.pullPageLimit {
                    break
                }
            }

            retryParkedRows()
        } catch {
            FileLog.shared.addMessage("PodHopper completions reconcile failed: \(error)")
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
        applyOne(episode: episode, positionSec: positionSec, totalSec: totalSec, completed: completed, remoteTs: remoteTs)
    }

    private func applyOne(episode: Episode, positionSec: Int, totalSec: Int, completed: Bool, remoteTs: Int64) {
        // Circuit breaker first, counting every row the sync tries to apply to this episode rather
        // than only the ones that change something, so a loop that keeps being turned away by the
        // guards below still trips it and still gets logged. Matches Android's placement.
        guard allowApply(uuid: episode.uuid) else {
            return
        }

        // Staleness guard, ahead of every decision: a row older than this device's own played-state
        // change must never undo it. This is what stops an un-mark made offline from being reverted
        // by the next pull. Both values are milliseconds, the remote one stamped by the database and
        // the local one by this device, so the comparison assumes network-synced clocks. That soft
        // spot is accepted, and matches Android.
        let localStatusTs = episode.playingStatusModified
        if localStatusTs > 0, remoteTs > 0, localStatusTs > remoteTs {
            return
        }

        let isCurrentlyPlayingThis = delegate?.currentlyPlayingEpisodeUuid() == episode.uuid
        let playingStatusIsNotPlayed = episode.playingStatus == PlayingStatus.notPlayed.rawValue
        let playingStatusIsCompleted = episode.playingStatus == PlayingStatus.completed.rawValue

        let decision = Self.decideApply(
            isCurrentlyPlayingThisEpisode: isCurrentlyPlayingThis,
            positionSec: positionSec,
            totalSec: totalSec,
            completed: completed,
            playingStatusIsNotPlayed: playingStatusIsNotPlayed,
            playingStatusIsCompleted: playingStatusIsCompleted
        )

        switch decision {
        case .skip:
            return
        case .complete:
            addApplying(episode.uuid)
            delegate?.markAsPlayed(episode: episode)
            removeApplying(episode.uuid)
        case .uncomplete(let remotePositionSec):
            // An episode finished before this app stamped played-state timestamps has nothing for
            // the staleness guard above to defend, so a regression row would silently undo it.
            // Require a stamped local change before regressing. Android never needed this because
            // it has always stamped; this only brings iOS up to that same precondition.
            if localStatusTs <= 0 {
                return
            }
            addApplying(episode.uuid)
            delegate?.markAsUnplayed(episode: episode)
            if remotePositionSec > 0 {
                delegate?.updatePlayedUpTo(episode: episode, positionSec: Double(remotePositionSec))
                delegate?.markInProgress(episode: episode)
            }
            removeApplying(episode.uuid)
        case .setPosition(let sec, let markInProgress):
            delegate?.updatePlayedUpTo(episode: episode, positionSec: sec)
            if markInProgress {
                delegate?.markInProgress(episode: episode)
            }
        }
    }

    /// Refuses more than [applyBreakerMaxApplies] sync applies to one episode inside
    /// [applyBreakerWindowMs]. A runaway apply loop is a bug; this bounds the damage and names the
    /// episode in the log. In memory only, so it resets with the process.
    private func allowApply(uuid: String) -> Bool {
        let now = nowMs()
        var refused = false
        var recentCount = 0

        stateLock.lock()
        var history = _applyHistory[uuid] ?? []
        history.removeAll { now - $0 > Self.applyBreakerWindowMs }
        if history.count >= Self.applyBreakerMaxApplies {
            refused = true
            recentCount = history.count
        } else {
            history.append(now)
        }
        _applyHistory[uuid] = history
        stateLock.unlock()

        if refused {
            FileLog.shared.addMessage("PodHopper sync circuit breaker tripped for episode \(uuid): \(recentCount) applies in the last hour, refusing more")
        }
        return !refused
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
        playingStatusIsNotPlayed: Bool,
        playingStatusIsCompleted: Bool
    ) -> ApplyDecision {
        if isCurrentlyPlayingThisEpisode {
            return .skip
        }
        if isCompletionRow(positionSec: positionSec, totalSec: totalSec, completed: completed) {
            return .complete
        }
        // The row says not finished. If it is finished here, another device un-marked it and that
        // wins, subject to the staleness guard the caller applies first.
        if playingStatusIsCompleted {
            return .uncomplete(positionSec)
        }
        if positionSec >= 0 {
            // Only real progress moves an episode to in-progress. An un-mark row carries position
            // zero, and must not flip an already-unplayed episode to in-progress.
            return .setPosition(Double(positionSec), markInProgress: playingStatusIsNotPlayed && positionSec > 0)
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
        case uncomplete(Int)
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
                completed: (entry["c"] as? Bool) ?? ((entry["c"] as? NSNumber)?.boolValue ?? false),
                remoteTs: (entry["u"] as? NSNumber)?.int64Value ?? 0
            )
            parked.removeValue(forKey: episodeKey)
            changed = true
        }
        if changed {
            writeParked(parked)
        }
    }

    // MARK: Pending push queue

    /// Saves rows a push could not send. One entry per episode, so a queue built over a long offline
    /// stretch stays proportional to the episodes touched rather than the actions taken.
    ///
    /// A later row for the same episode is merged over the earlier one rather than replacing it: a
    /// position sample omits the completed column, and replacing would silently discard a completion
    /// queued moments earlier. An older row never overwrites a newer one.
    private func enqueuePending(_ rows: [[String: Any]]) {
        if rows.isEmpty {
            return
        }
        var pending = readPending()
        for row in rows {
            guard let key = row["episode_key"] as? String, !key.isEmpty else { continue }
            let newTs = (row["updated_at_ms"] as? NSNumber)?.int64Value ?? 0
            guard var existing = pending[key] else {
                pending[key] = row
                continue
            }
            let existingTs = (existing["updated_at_ms"] as? NSNumber)?.int64Value ?? 0
            if newTs < existingTs {
                continue
            }
            for (field, value) in row {
                existing[field] = value
            }
            pending[key] = existing
        }

        if pending.count > Self.maxPending {
            let oldestFirst = pending.sorted { lhs, rhs in
                ((lhs.value["updated_at_ms"] as? NSNumber)?.int64Value ?? 0) < ((rhs.value["updated_at_ms"] as? NSNumber)?.int64Value ?? 0)
            }
            let dropCount = pending.count - Self.maxPending
            for entry in oldestFirst.prefix(dropCount) {
                pending.removeValue(forKey: entry.key)
            }
        }
        writePending(pending)
    }

    /// Sends queued rows, stamping the user id now that the device is online. Never throws: a retry
    /// queue is an addition to sync, never a precondition for it.
    ///
    /// Each row is checked against what the backend currently holds and dropped when the backend is
    /// already at least as new. The upsert is unconditional and the database's own last-writer-wins
    /// trigger cannot help here, because the server stamps every incoming row with the current time,
    /// so without this check a queued row would overwrite a newer write from another device: finish
    /// an episode offline on the phone, replay it in the car, and the phone would re-complete it on
    /// reconnect.
    private func drainPendingPushes() {
        let pending = readPending()
        if pending.isEmpty {
            return
        }
        do {
            guard let userId = try supabase.getUserId() else {
                return
            }

            // Episode keys go straight into a query string, and the client force unwraps
            // URL(string:), so a key carrying a character that is illegal in a URL would crash
            // rather than fail. Every key this app generates is a hyphenated hex uuid, so this
            // filter should never exclude anything; a key that somehow does is left queued rather
            // than sent blind, because without a backend comparison it could overwrite newer state.
            let safeKeyCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
            let keys = pending.keys.filter { key in
                !key.isEmpty && key.rangeOfCharacter(from: safeKeyCharacters.inverted) == nil
            }
            if keys.count != pending.count {
                FileLog.shared.addMessage("PodHopper pending push drain: \(pending.count - keys.count) queued row(s) have an unexpected episode key and are being held back")
            }
            if keys.isEmpty {
                return
            }

            var backendTs = [String: Int64]()
            var looked = 0
            while looked < keys.count {
                let end = min(looked + Self.pendingLookupChunkSize, keys.count)
                let list = keys[looked ..< end].joined(separator: ",")
                let rows = try supabase.select(table: Self.table, query: "select=episode_key,updated_at_ms&episode_key=in.(\(list))")
                for row in rows {
                    guard let key = row["episode_key"] as? String else { continue }
                    backendTs[key] = (row["updated_at_ms"] as? NSNumber)?.int64Value ?? 0
                }
                looked = end
            }

            var remaining = pending
            var sendable = [[String: Any]]()
            for key in keys {
                guard let row = pending[key] else { continue }
                let ourTs = (row["updated_at_ms"] as? NSNumber)?.int64Value ?? 0
                if let theirs = backendTs[key], theirs >= ourTs {
                    remaining.removeValue(forKey: key)
                    continue
                }
                var wire = row
                wire["user_id"] = userId
                sendable.append(wire)
            }

            var sent = 0
            while sent < sendable.count {
                let end = min(sent + Self.pushChunkSize, sendable.count)
                let chunk = Array(sendable[sent ..< end])
                do {
                    try supabase.upsert(table: Self.table, onConflictColumns: "user_id,episode_key", rows: chunk)
                    for row in chunk {
                        if let key = row["episode_key"] as? String {
                            remaining.removeValue(forKey: key)
                        }
                    }
                } catch {
                    // Only this batch stays queued.
                    FileLog.shared.addMessage("PodHopper pending push batch failed, staying queued: \(error)")
                }
                sent = end
            }
            writePending(remaining)
        } catch {
            // Everything stays queued for the next sync.
            FileLog.shared.addMessage("PodHopper pending push drain failed, staying queued: \(error)")
        }
    }

    private func readPending() -> [String: [String: Any]] {
        guard let data = defaults.data(forKey: Self.pendingKey) else { return [:] }
        let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]]
        return parsed ?? [:]
    }

    private func writePending(_ pending: [String: [String: Any]]) {
        if pending.isEmpty {
            defaults.removeObject(forKey: Self.pendingKey)
            return
        }
        if let data = try? JSONSerialization.data(withJSONObject: pending) {
            defaults.set(data, forKey: Self.pendingKey)
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

    /// This device's install id, shared with the other PodHopper sync engines so every table
    /// records the same device rather than each engine minting its own identity.
    public func deviceInstallId() -> String {
        installId()
    }

    /// This device's display name, shared with the other PodHopper sync engines.
    public func deviceDisplayName() -> String {
        deviceName()
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

    /// Resets this device's position sync bookkeeping so a future account starts clean. Clears both
    /// cursors and parked rows, sending the delta cursor back to the first-sync sentinel. The install
    /// id is kept, since it identifies the device, not the account. Does not touch any episode,
    /// podcast, or playback data.
    public func clearLocalSyncState() {
        defaults.removeObject(forKey: Self.lastPullMsKey)
        defaults.removeObject(forKey: Self.parkedKey)
        defaults.removeObject(forKey: Self.completionsCursorKey)
        defaults.removeObject(forKey: Self.pendingKey)
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
    private static let completionsCursorKey = "completions_cursor_ms"
    private static let parkedKey = "parked_rows"
    private static let pendingKey = "pending_pushes"
    private static let minPushIntervalMs: Int64 = 4000
    private static let playPullTimeoutMs: Int64 = 5000
    private static let reconcileMinIntervalMs: Int64 = 5000
    private static let adoptScanLimit = 10
    private static let firstSyncSentinel: Int64 = -1
    private static let maxParked = 500
    private static let maxPending = 500
    private static let pendingLookupChunkSize = 50
    private static let pushChunkSize = 100
    private static let applyBreakerWindowMs: Int64 = 3_600_000
    private static let applyBreakerMaxApplies = 6
}
