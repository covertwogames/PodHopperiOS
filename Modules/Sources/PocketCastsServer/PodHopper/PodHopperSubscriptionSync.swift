import Combine
import Foundation
import PocketCastsDataModel
import PocketCastsUtils

/// Syncs podcast subscriptions across devices through Supabase, so a podcast added on one device
/// shows up on the others. A direct port of the Android `PodHopperSubscriptionSync`, which is itself
/// the AntennaPod approach that worked.
///
/// Local subscribe and unsubscribe actions are written into a persisted queue (added / removed). One
/// sync pass then runs: download remote changes newer than a saved timestamp cursor, apply them
/// locally, upload whatever is in the local queue (minus anything that just arrived), clear the
/// queue, and advance the cursor. The cursor is what prevents echoes: a device only downloads rows
/// newer than the last it saw, so its own writes come back at most once, no-op, and the cursor moves
/// past them.
///
/// Subscriptions are keyed by feed url, which every device agrees on. Because an unsubscribe can
/// remove the local podcast row before we read its feed url, each subscribe also remembers the feed
/// url keyed by the podcast uuid, so a later unsubscribe can still be pushed.
///
/// The engine lives in the shared module so the phone, CarPlay (same process), and the Watch app can
/// all drive it. Unsubscribing a podcast is app-level work (it cleans up downloads, playlists, and
/// Up Next), so the host sets `unsubscribeHandler`; applying a remote removal calls through it.
public final class PodHopperSubscriptionSync {

    public static let shared = PodHopperSubscriptionSync()

    /// Set by the host so the engine can apply a remote unsubscribe through the app's real
    /// unsubscribe path. Given a podcast uuid that is currently subscribed locally.
    public var unsubscribeHandler: ((_ uuid: String) -> Void)?

    private let supabase: PodHopperSupabaseClient
    private let feedManager: PodHopperFeedManager
    private let dataManager: DataManager
    private let defaults: UserDefaults

    private let workQueue = DispatchQueue(label: "au.com.podhopper.subscriptionsync", qos: .utility)
    private let stateLock = NSLock()
    private var _applyingRemote = false
    private var _syncInFlight = false
    private var _lastPollMs: Int64 = 0
    private var periodicTimer: DispatchSourceTimer?

    private var cancellables = Set<AnyCancellable>()

    public init(
        supabase: PodHopperSupabaseClient = .shared,
        feedManager: PodHopperFeedManager = .shared,
        dataManager: DataManager = .sharedManager,
        defaults: UserDefaults = UserDefaults(suiteName: PodHopperSubscriptionSync.suiteName) ?? .standard
    ) {
        self.supabase = supabase
        self.feedManager = feedManager
        self.dataManager = dataManager
        self.defaults = defaults
        observeSubscriptionChanges()
        observeSignIn()
    }

    // MARK: Triggers

    /// Every local subscribe path converges on the feed manager's `subscriptionChanged`, so listening
    /// here records the change into the queue without hooking each screen. The `applyingRemote` check
    /// is synchronous on the emitting thread so a change applied by our own pull is not queued back
    /// up; this depends on `subscriptionChanged` delivering synchronously (no scheduler hop).
    private func observeSubscriptionChanges() {
        feedManager.subscriptionChanged
            .sink { [weak self] uuid in
                guard let self else { return }
                if self.isApplyingRemote() {
                    return
                }
                self.workQueue.async {
                    self.enqueueLocalChange(uuid: uuid)
                    self.pullSubscriptions()
                }
            }
            .store(in: &cancellables)
    }

    /// Pulls the instant sign-in completes, so a freshly signed-in user lands on a populated library
    /// instead of waiting for the next trigger. The startup value is dropped, so only a real
    /// transition into the signed-in state triggers a pull; sign-out does not.
    private func observeSignIn() {
        supabase.loginState
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] loggedIn in
                if loggedIn {
                    self?.pullSubscriptions()
                }
            }
            .store(in: &cancellables)
    }

    /// Enqueues an explicit change and runs a sync pass. Used by the app's unsubscribe paths, which
    /// have the feed url in hand (an unsubscribe may delete the podcast row before we could read it).
    public func pushSubscription(feedUrl: String, subscribed: Bool) {
        let trimmed = feedUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return
        }
        workQueue.async {
            if subscribed {
                self.queueAdd(trimmed)
            } else {
                self.queueRemove(trimmed)
            }
            self.pullSubscriptions()
        }
    }

    /// Runs one full sync pass. Safe to call on foreground, on sign-in, and after a local change. A
    /// pass requested while one is already in flight is skipped; its work is covered by the running
    /// pass or the next trigger, and queued local changes persist until then.
    public func pullSubscriptions() {
        if !supabase.isLoggedIn() {
            return
        }
        if !beginSyncIfIdle() {
            return
        }
        setLastPollMs(nowMs())
        workQueue.async {
            defer { self.endSync() }
            do {
                try self.runSync()
            } catch {
                FileLog.shared.addMessage("PodHopper subscription sync failed: \(error)")
            }
        }
    }

    /// Throttled pull for frequent triggers like navigation and the foreground timer. Skips if a pull
    /// already ran within the throttle window.
    public func pollSubscriptions() {
        if nowMs() - lastPollMs() < Self.minPollIntervalMs {
            return
        }
        pullSubscriptions()
    }

    /// Starts a foreground poll loop so an already-open device notices changes from other devices
    /// without being reopened. First poll runs immediately, then every interval. Call from the
    /// foreground lifecycle (app, CarPlay scene, or Watch). Safe to call repeatedly.
    public func startPeriodicSync() {
        stateLock.lock(); defer { stateLock.unlock() }
        if periodicTimer != nil {
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(Int(Self.periodicSyncIntervalMs)))
        timer.setEventHandler { [weak self] in
            self?.pollSubscriptions()
        }
        periodicTimer = timer
        timer.resume()
    }

    /// Stops the foreground poll loop. Call from the background lifecycle.
    public func stopPeriodicSync() {
        stateLock.lock(); defer { stateLock.unlock() }
        periodicTimer?.cancel()
        periodicTimer = nil
    }

    // MARK: Enqueue

    private func enqueueLocalChange(uuid: String) {
        if let podcast = dataManager.findPodcast(uuid: uuid, includeUnsubscribed: true), podcast.isSubscribed() {
            let feedUrl = (podcast.podcastUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !feedUrl.isEmpty {
                rememberFeedUrl(uuid: uuid, feedUrl: feedUrl)
                queueAdd(feedUrl)
            }
        } else {
            // The podcast row is gone or unsubscribed; recover its feed url from the remembered map.
            if let feedUrl = recallFeedUrl(uuid: uuid), !feedUrl.isEmpty {
                queueRemove(feedUrl)
                forgetFeedUrl(uuid: uuid)
            }
        }
    }

    // MARK: Sync pass

    private func runSync() throws {
        let lastSync = cursor()
        let localSubscriptions = dataManager.allPodcasts(includeUnsubscribed: false)
            .compactMap { $0.podcastUrl?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let query = "select=feed_url,subscribed,updated_at_ms"
            + "&updated_at_ms=gt.\(lastSync)"
            + "&order=updated_at_ms.asc"
            + "&limit=\(PodHopperConfig.pullPageLimit)"
        let rows = try supabase.select(table: Self.table, query: query)

        let remoteRows: [(feedUrl: String, subscribed: Bool, updatedAtMs: Int64)] = rows.compactMap { row in
            guard let feedUrl = (row["feed_url"] as? String), !feedUrl.isEmpty else { return nil }
            let subscribed = (row["subscribed"] as? Bool) ?? ((row["subscribed"] as? NSNumber)?.boolValue ?? false)
            let updatedAtMs = (row["updated_at_ms"] as? NSNumber)?.int64Value ?? 0
            return (feedUrl, subscribed, updatedAtMs)
        }

        let queuedAdded = readQueue(Self.queueAddedKey)
        let queuedRemoved = readQueue(Self.queueRemovedKey)

        let plan = Self.reconcile(
            lastSync: lastSync,
            localSubscriptions: localSubscriptions,
            remoteRows: remoteRows,
            queuedAdded: queuedAdded,
            queuedRemoved: queuedRemoved
        )

        setApplyingRemote(true)
        do {
            for feedUrl in plan.toSubscribe {
                feedManager.subscribeToFeedUrl(feedUrl)
            }
            for feedUrl in plan.toUnsubscribe {
                let uuid = PodHopperUUID.podcastUuid(forFeed: feedUrl)
                if let podcast = dataManager.findPodcast(uuid: uuid, includeUnsubscribed: true), podcast.isSubscribed() {
                    unsubscribeHandler?(uuid)
                }
            }
        }
        setApplyingRemote(false)

        if plan.addsToUpload.isEmpty && plan.removesToUpload.isEmpty {
            clearQueues()
        } else {
            try uploadChanges(added: plan.addsToUpload, removed: plan.removesToUpload)
            clearQueues()
        }

        if plan.newestCursor > lastSync {
            setCursor(plan.newestCursor)
        }
    }

    /// The pure reconciliation: given the cursor, the local subscribed feeds, the remote rows newer
    /// than the cursor, and the pending queues, decide what to apply locally, what to upload, and the
    /// new cursor. Echo prevention and first-sync behaviour live here, so they are unit tested without
    /// any network or database. Mirrors the Android `runSync` set math exactly.
    static func reconcile(
        lastSync: Int64,
        localSubscriptions: [String],
        remoteRows: [(feedUrl: String, subscribed: Bool, updatedAtMs: Int64)],
        queuedAdded: [String],
        queuedRemoved: [String]
    ) -> SyncPlan {
        var remoteAdded: [String] = []
        var remoteRemoved: [String] = []
        var newest = lastSync
        for row in remoteRows {
            if row.subscribed {
                remoteAdded.append(row.feedUrl)
            } else {
                remoteRemoved.append(row.feedUrl)
            }
            if row.updatedAtMs > newest {
                newest = row.updatedAtMs
            }
        }

        let localSet = Set(localSubscriptions)
        let queuedAddedSet = Set(queuedAdded)
        let queuedRemovedSet = Set(queuedRemoved)
        let remoteAddedSet = Set(remoteAdded)
        let remoteRemovedSet = Set(remoteRemoved)

        // Apply remote adds, skipping feeds we already have or just removed locally.
        let toSubscribe = remoteAdded.filter { !localSet.contains($0) && !queuedRemovedSet.contains($0) }
        // Apply remote removes, skipping feeds we just re-subscribed to locally. The actual
        // "still subscribed locally?" check happens at apply time against the database.
        let toUnsubscribe = remoteRemoved.filter { !queuedAddedSet.contains($0) }

        // On the first sync, push the whole local library up so the cloud starts consistent.
        var addsToUpload = (lastSync == 0) ? localSubscriptions : queuedAdded
        // Do not re-upload anything that just came down in this same pass.
        addsToUpload = addsToUpload.filter { !remoteAddedSet.contains($0) }
        let removesToUpload = queuedRemoved.filter { !remoteRemovedSet.contains($0) }

        return SyncPlan(
            toSubscribe: toSubscribe,
            toUnsubscribe: toUnsubscribe,
            addsToUpload: addsToUpload,
            removesToUpload: removesToUpload,
            newestCursor: newest
        )
    }

    struct SyncPlan: Equatable {
        let toSubscribe: [String]
        let toUnsubscribe: [String]
        let addsToUpload: [String]
        let removesToUpload: [String]
        let newestCursor: Int64
    }

    private func uploadChanges(added: [String], removed: [String]) throws {
        guard let userId = try supabase.getUserId() else { return }
        let now = nowMs()
        var rows: [[String: Any]] = []
        for feedUrl in added {
            rows.append(subscriptionRow(userId: userId, feedUrl: feedUrl, subscribed: true, timestampMs: now))
        }
        for feedUrl in removed {
            rows.append(subscriptionRow(userId: userId, feedUrl: feedUrl, subscribed: false, timestampMs: now))
        }
        if !rows.isEmpty {
            try supabase.upsert(table: Self.table, onConflictColumns: "user_id,feed_url", rows: rows)
        }
    }

    private func subscriptionRow(userId: String, feedUrl: String, subscribed: Bool, timestampMs: Int64) -> [String: Any] {
        [
            "user_id": userId,
            "feed_url": feedUrl,
            "subscribed": subscribed,
            "updated_at_ms": timestampMs,
        ]
    }

    // MARK: Queue persistence

    private func queueAdd(_ feedUrl: String) {
        addToQueue(Self.queueAddedKey, feedUrl)
        removeFromQueue(Self.queueRemovedKey, feedUrl)
    }

    private func queueRemove(_ feedUrl: String) {
        addToQueue(Self.queueRemovedKey, feedUrl)
        removeFromQueue(Self.queueAddedKey, feedUrl)
    }

    private func readQueue(_ key: String) -> [String] {
        (defaults.array(forKey: key) as? [String]) ?? []
    }

    private func writeQueue(_ key: String, _ values: [String]) {
        defaults.set(values, forKey: key)
    }

    private func addToQueue(_ key: String, _ feedUrl: String) {
        var values = readQueue(key)
        if !values.contains(feedUrl) {
            values.append(feedUrl)
            writeQueue(key, values)
        }
    }

    private func removeFromQueue(_ key: String, _ feedUrl: String) {
        var values = readQueue(key)
        if let index = values.firstIndex(of: feedUrl) {
            values.remove(at: index)
            writeQueue(key, values)
        }
    }

    private func clearQueues() {
        defaults.set([String](), forKey: Self.queueAddedKey)
        defaults.set([String](), forKey: Self.queueRemovedKey)
    }

    // MARK: Feed-url memory

    private func rememberFeedUrl(uuid: String, feedUrl: String) {
        defaults.set(feedUrl, forKey: Self.feedPrefix + uuid)
    }

    private func recallFeedUrl(uuid: String) -> String? {
        defaults.string(forKey: Self.feedPrefix + uuid)
    }

    private func forgetFeedUrl(uuid: String) {
        defaults.removeObject(forKey: Self.feedPrefix + uuid)
    }

    // MARK: Cursor

    private func cursor() -> Int64 {
        Int64(defaults.integer(forKey: Self.lastPullMsKey))
    }

    private func setCursor(_ value: Int64) {
        defaults.set(Int(value), forKey: Self.lastPullMsKey)
    }

    /// Resets this device's subscription sync bookkeeping so a future account starts clean. Clears
    /// the cursor, both queues, and the remembered feed-url map. With the cursor back at zero, the
    /// next sign-in does a full first-sync upload of the local library. Does not unsubscribe anything
    /// or remove any podcast from the device.
    public func clearLocalSyncState() {
        defaults.removePersistentDomain(forName: Self.suiteName)
    }

    // MARK: Guarded state

    private func isApplyingRemote() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _applyingRemote
    }

    private func setApplyingRemote(_ value: Bool) {
        stateLock.lock(); _applyingRemote = value; stateLock.unlock()
    }

    private func beginSyncIfIdle() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        if _syncInFlight { return false }
        _syncInFlight = true
        return true
    }

    private func endSync() {
        stateLock.lock(); _syncInFlight = false; stateLock.unlock()
    }

    private func lastPollMs() -> Int64 {
        stateLock.lock(); defer { stateLock.unlock() }
        return _lastPollMs
    }

    private func setLastPollMs(_ value: Int64) {
        stateLock.lock(); _lastPollMs = value; stateLock.unlock()
    }

    private func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    // MARK: Constants

    public static let suiteName = "podhopper_subscription_sync"
    private static let table = "subscriptions"
    private static let lastPullMsKey = "last_subs_pull_ms"
    private static let queueAddedKey = "sync_added"
    private static let queueRemovedKey = "sync_removed"
    private static let feedPrefix = "feedfor_"
    private static let periodicSyncIntervalMs: Int64 = 30_000
    private static let minPollIntervalMs: Int64 = 1_000
}
