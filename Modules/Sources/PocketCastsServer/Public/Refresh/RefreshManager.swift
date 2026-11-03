import Foundation
import PocketCastsDataModel
import PocketCastsUtils
import UIKit
#if os(watchOS)
    import WatchKit
#endif

public class RefreshManager {
    public static let shared = RefreshManager()

    lazy var refreshQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1

        return queue
    }()

    // the watch has less resources than a phone, so be a bit more aggressive about not refreshing constantly
    #if os(watchOS)
        private static let minTimeBetweenRefreshes = 1.minute
    #else
        private static let minTimeBetweenRefreshes = 15.seconds
    #endif

    public func syncUpNext() {
        if !SyncManager.isUserLoggedIn() { return }

        // if the user has an active subscription, there might be custom episodes in their Up Next, so grab those first
        if SubscriptionHelper.hasActiveSubscription() {
            refreshQueue.addOperation(RetrieveCustomFilesTask())
        }
        refreshQueue.addOperation(UpNextSyncTask())
    }


    /// Updates a podcast and all the associated information.
    ///
    /// Note that this will force all the episodes to be updated.
    /// - Parameter podcast: a `Podcast` object
    public func refresh(podcast: Podcast, from episodeUuid: String) {
        podcast.forceRefreshEpisodeFrom = episodeUuid
        refresh(podcasts: [podcast]) {
            if SyncManager.isUserLoggedIn() {
                guard let episodes = ApiServerHandler.shared.retrieveEpisodeTaskSynchronouusly(podcastUuid: podcast.uuid) else { return }

                DataManager.sharedManager.saveBulkEpisodeSyncInfo(episodes: DataConverter.convert(syncInfoEpisodes: episodes))
                podcast.forceRefreshEpisodeFrom = nil
            }
        }
    }

    public func refresh(podcast: Podcast, from episodeUuid: String) async {
        podcast.forceRefreshEpisodeFrom = episodeUuid
        // The continuation's type is spelled out because its only resume is inside a defer, and Swift
        // doesn't look inside a defer when it works out a closure's types.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            refresh(podcasts: [podcast]) {
                // PodHopper: resume however this ends. Returning early without resuming left the caller
                // (the podcast page's pull to refresh) waiting forever.
                defer { continuation.resume() }

                if SyncManager.isUserLoggedIn() {
                    guard let episodes = ApiServerHandler.shared.retrieveEpisodeTaskSynchronouusly(podcastUuid: podcast.uuid) else { return }

                    DataManager.sharedManager.saveBulkEpisodeSyncInfo(episodes: DataConverter.convert(syncInfoEpisodes: episodes))
                    podcast.forceRefreshEpisodeFrom = nil
                }
            }
        }
    }

    public func refreshPodcasts(forceEvenIfRefreshedRecently: Bool = false) {
        if !forceEvenIfRefreshedRecently {
            if let lastRefreshStartTime = ServerSettings.lastRefreshStartTime(), fabs(lastRefreshStartTime.timeIntervalSinceNow) < RefreshManager.minTimeBetweenRefreshes {
                // if it's been less than minTimeBetweenRefreshes since our last refresh, don't do another one. Effectively throttling user refreshes a little bit
                FileLog.shared.addMessage("Refresh - Throttled")
                DispatchQueue.global().async {
                    Thread.sleep(forTimeInterval: 1.second)
                    ServerNotificationsHelper.shared.firePodcastsUpdated()
                    NotificationCenter.default.post(name: ServerNotifications.podcastRefreshThrottled, object: nil)
                }

                return
            }
        }

        // A forced refresh is asked for after something changed, such as signing in, so it doesn't join a
        // refresh that started before the change. It can still join one that's waiting to start.
        requestFullRefresh(recordsStartTime: true, canJoinRunningRefresh: !forceEvenIfRefreshedRecently, completion: nil)
    }

    /// Refreshes particular podcasts, such as the one a podcast page asks for. It starts straight away
    /// rather than waiting for a refresh of everything to finish: each refresh keeps its own feed
    /// validators, so running alongside one is safe, and it's only a feed or two.
    private func refresh(podcasts: [Podcast], completion: (() -> Void)? = nil) {
        let request = RefreshRequest(podcasts: podcasts, recordsStartTime: true) { _ in
            completion?()
        }
        start(request)
    }

    /// Refreshes every subscribed podcast and reports the result. By default it joins a refresh that's
    /// already running; pass false when the caller needs one that starts after this call.
    public func refreshPodcasts(canJoinRunningRefresh: Bool = true, completion: @escaping (RefreshFetchResult) -> Void) {
        requestFullRefresh(recordsStartTime: false, canJoinRunningRefresh: canJoinRunningRefresh, completion: completion)
    }

    public func cancelAllRefreshes() {
        refreshQueue.cancelAllOperations()
    }

    // MARK: - One refresh of every podcast at a time

    /// A refresh that's running or waiting to run, and everyone waiting for it to finish.
    private final class RefreshRequest {
        /// The podcasts to refresh, or nil for every subscribed podcast, read when the refresh starts.
        let podcasts: [Podcast]?
        var recordsStartTime: Bool
        var completions: [(RefreshFetchResult) -> Void]

        init(podcasts: [Podcast]?, recordsStartTime: Bool, completion: ((RefreshFetchResult) -> Void)?) {
            self.podcasts = podcasts
            self.recordsStartTime = recordsStartTime
            if let completion {
                completions = [completion]
            } else {
                completions = []
            }
        }
    }

    private let refreshStateLock = NSLock()
    /// The refresh of every podcast that's running, and the one waiting to start after it.
    private var runningRefresh: RefreshRequest?
    private var waitingRefresh: RefreshRequest?

    /// PodHopper: refreshes of every podcast run one at a time. Two at once fetched and parsed every
    /// feed twice, doubling the memory and network used. A new one joins one that's waiting to start,
    /// or one that's already running when `canJoinRunningRefresh` allows, instead of running again
    /// straight after it. Every completion is called once, when the refresh it's attached to finishes.
    private func requestFullRefresh(recordsStartTime: Bool, canJoinRunningRefresh: Bool, completion: ((RefreshFetchResult) -> Void)?) {
        refreshStateLock.lock()

        if canJoinRunningRefresh, let running = runningRefresh {
            if let completion {
                running.completions.append(completion)
            }
            refreshStateLock.unlock()
            FileLog.shared.addMessage("Refresh - Joined the refresh already running")
            return
        }

        if let waiting = waitingRefresh {
            waiting.recordsStartTime = waiting.recordsStartTime || recordsStartTime
            if let completion {
                waiting.completions.append(completion)
            }
            refreshStateLock.unlock()
            FileLog.shared.addMessage("Refresh - Joined the refresh waiting to start")
            return
        }

        let request = RefreshRequest(podcasts: nil, recordsStartTime: recordsStartTime, completion: completion)
        let startNow = runningRefresh == nil
        if startNow {
            runningRefresh = request
        } else {
            waitingRefresh = request
            FileLog.shared.addMessage("Refresh - Waiting for the refresh already running")
        }
        refreshStateLock.unlock()

        if startNow {
            start(request)
        }
    }

    private func start(_ request: RefreshRequest) {
        refreshStateLock.lock()
        let recordsStartTime = request.recordsStartTime
        refreshStateLock.unlock()

        if recordsStartTime {
            UserDefaults.standard.set(Date(), forKey: ServerConstants.UserDefaults.lastRefreshStartTime)
        }

        // Holds on to the manager strongly. It's a singleton, and on watchOS 10 a weak reference here got
        // the app killed by the system.
        DispatchQueue.global().async {
            let podcasts = request.podcasts ?? DataManager.sharedManager.allPodcasts(includeUnsubscribed: false)
            MainServerHandler.shared.refresh(podcasts: podcasts) { refreshResponse in
                self.processPodcastRefreshResponse(refreshResponse) { result in
                    self.finish(request, result: result)
                }
            }
        }
    }

    private func finish(_ request: RefreshRequest, result: RefreshFetchResult) {
        refreshStateLock.lock()
        let completions = request.completions
        request.completions = []
        var next: RefreshRequest?
        if runningRefresh === request {
            next = waitingRefresh
            waitingRefresh = nil
            runningRefresh = next
        }
        refreshStateLock.unlock()

        if let next {
            start(next)
        }

        for completion in completions {
            completion(result)
        }
    }

    private func processPodcastRefreshResponse(_ refreshResponse: PodcastRefreshResponse?, completion: @escaping (RefreshFetchResult) -> Void) {
        guard let response = refreshResponse, response.success() else {
            FileLog.shared.addMessage("Podcast refresh failed with message: \(refreshResponse?.message ?? "none"). See previous log for more details.")
            ServerNotificationsHelper.shared.firePodcastRefreshFailed()
            completion(.failed)

            return
        }

        guard let result = response.result else {
            // PodHopper: a successful response always carries a result, but if one ever didn't, still
            // report back so nothing waits on this refresh forever.
            FileLog.shared.addMessage("Podcast refresh returned no result")
            ServerNotificationsHelper.shared.firePodcastRefreshFailed()
            completion(.failed)

            return
        }

        let refreshOperation = RefreshOperation(result: result, completionHandler: completion)
        refreshQueue.addOperation(refreshOperation)
    }
}
