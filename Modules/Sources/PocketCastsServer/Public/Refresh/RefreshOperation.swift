import PocketCastsDataModel
import PocketCastsUtils
import UIKit

class RefreshOperation: Operation, @unchecked Sendable {
    private var refreshResult: RefreshResult

    private var completionHandler: ((RefreshFetchResult) -> Void)?

    // PodHopper: the completion handler is called exactly once on every path, including when the refresh is
    // cancelled, because callers depend on it: a background task that isn't completed gets the app ended,
    // and `RefreshManager` won't start the next refresh until this one reports back.
    private let completionLock = NSLock()
    private var hasCalledCompletion = false

    private lazy var apiQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1

        return queue
    }()

    init(result: RefreshResult, completionHandler: ((RefreshFetchResult) -> Void)?) {
        refreshResult = result
        self.completionHandler = completionHandler
        super.init()

        // Runs once the operation has finished, including when it was cancelled before it started and
        // `main` never ran. After any other path the completion has already been called, so this does nothing.
        completionBlock = {
            self.callCompletion(.failed)
        }
    }

    private func callCompletion(_ result: RefreshFetchResult) {
        completionLock.lock()
        let handler: ((RefreshFetchResult) -> Void)? = hasCalledCompletion ? nil : completionHandler
        hasCalledCompletion = true
        completionLock.unlock()

        handler?(result)
    }

    override func main() {
        autoreleasepool {
            if isCancelled {
                cleanupAfterCancel()
                callCompletion(.failed)

                return
            }

            let trace = TraceManager.shared.beginTracing(eventName: "SERVER_REFRESH")
            defer { TraceManager.shared.endTracing(trace: trace) }

            // look for new podcasts from the server
            let refreshResult = performRefresh()

            // if this operation fails, or our operation was cancelled, let the completion handler know and stop
            if refreshResult == .failed || refreshResult == .cancelled {
                FileLog.shared.addMessage("Refresh \(refreshResult == .failed ? "failed" : "was cancelled")")
                ServerNotificationsHelper.shared.firePodcastRefreshFailed()
                callCompletion(.failed)
                return
            }

            // let various bits of the app know we have finished the refresh
            ServerNotificationsHelper.shared.firePodcastRefreshSucceeded()

            if isCancelled {
                cleanupAfterCancel()
                callCompletion(.failed)

                return
            }

            // refresh is done, now perform a sync if the user has a sync account
            if SyncManager.isUserLoggedIn() {
                NotificationCenter.default.post(name: ServerNotifications.syncStarted, object: nil)

                if SubscriptionHelper.hasActiveSubscription() { apiQueue.addOperation(RetrieveCustomFilesTask()) }
                apiQueue.addOperation(UpNextSyncTask())
                let syncTask = SyncTask()
                apiQueue.addOperation(syncTask)

                apiQueue.addOperation(SyncHistoryTask())

                apiQueue.addOperation(SyncSettingsTask())

                #if !os(watchOS)
                    ServerSettings.iapUnverifiedPurchaseReceiptDate() == nil ? apiQueue.addOperation(SubscriptionStatusTask()) : apiQueue.addOperation(PurchaseReceiptTask())
                #endif

                #if !os(watchOS)
                    // update our local copy of the remote stats. Doesn't really matter if this fails or succeeds
                    StatsManager.shared.loadRemoteStats(completion: nil)
                #endif

                apiQueue.waitUntilAllOperationsAreFinished()

                // we use the sync task as the main indication of whether the sync has failed
                let syncResult = syncTask.status
                if syncResult == .failed || syncResult == .cancelled {
                    callCompletion(.failed)
                } else {
                    // however we use the refresh to indicate to iOS whether we found new stuff or not
                    callCompletion(refreshResult == .successNewData ? .newData : .noData)

                    FileLog.shared.addMessage("Sync succeeded")

                    ServerNotificationsHelper.shared.fireSyncCompleted()
                    ServerConfig.shared.syncDelegate?.playlistChanged()
                }
            } else { // no sync required, we're done
                callCompletion(refreshResult == .successNewData ? .newData : .noData)
            }

            ServerConfig.shared.syncDelegate?.applyAutoArchivingToAllPodcasts()

            processAutoAddUpNextCandidates()

            ServerConfig.shared.syncDelegate?.performActionsAfterSync()
        }
    }

    func performRefresh() -> UpdateStatus {
        if isCancelled {
            cleanupAfterCancel()

            return .cancelled
        }

        var newEpisodesAdded = 0

        // the returned dictionary is indexed by podcast UUID and contains all the new episodes for that podcast
        let podcasts = DataManager.sharedManager.allPodcasts(includeUnsubscribed: false)
        let updatedPodcasts = refreshResult.podcastUpdates
        var metadataRequestsQueued = 0
        for podcast in podcasts {
            // PodHopper: the on-device refresh already leaves out episodes that are stored, so a feed that
            // changed with nothing new arrives as an empty list. It still goes through here, as it did when
            // the full feed was passed along, so the podcast's latest episode info is still checked below.
            guard let podcastEpisodes = updatedPodcasts?[podcast.uuid] else { continue }

            let episodes: [Episode] = podcastEpisodes.reversed().compactMap({ episode in
                guard let episodeUuid = episode.uuid else { return nil }
                if let _ = DataManager.sharedManager.findEpisode(uuid: episodeUuid) { return nil }

                let newEpisode = Episode()
                newEpisode.podcast_id = podcast.id
                newEpisode.podcastUuid = podcast.uuid
                newEpisode.playingStatus = PlayingStatus.notPlayed.rawValue
                newEpisode.episodeStatus = DownloadStatus.notDownloaded.rawValue
                newEpisode.addedDate = Date()
                newEpisode.populate(fromEpisode: episode)
                return newEpisode
            })

            DataManager.sharedManager.bulkSave(episodes: episodes)

            for episode in episodes {
                if isCancelled {
                    cleanupAfterCancel()

                    return .cancelled
                }

                // store episodes that we might possibly add to Up Next for processing after a sync
                if podcast.autoAddToUpNextOn() {
                    DataManager.sharedManager.autoAddCandidates.add(podcastUUID: podcast.uuid, episodeUUID: episode.uuid)
                }

                #if !os(watchOS)
                    // so we don't flood the users phone, set a limit on the amount of meta data requests made. So if they open it after
                    // 4 weeks of not using it doesn't sit there for years
                    if metadataRequestsQueued < 10 {
                        MetadataUpdater.shared.updatedMetadata(episodeUuid: episode.uuid)
                        metadataRequestsQueued += 1
                    }
                #endif
            }

            newEpisodesAdded += episodes.count

            // there's at least one new episode, so update the latestEpisodeUuid
            ServerPodcastManager.shared.updateLatestEpisodeInfo(podcast: podcast, setDefaults: false)
        }

        // PodHopper: the episodes from this refresh are saved, so it is now safe to remember what
        // each host told us about its feed. Until this point the validators are only held in memory.
        // Only for podcasts still followed, the ones processed above: a show unsubscribed while the
        // refresh ran has had its validators cleared, and writing them back would leave it answered
        // "not modified" with no episodes if it's followed again.
        let followedFeedUrls = Set(podcasts.compactMap(\.podcastUrl))
        for (feedUrl, validators) in refreshResult.feedValidators where followedFeedUrls.contains(feedUrl) {
            PodHopperFeedValidators.shared.store(validators, for: feedUrl)
        }

        ServerConfig.shared.syncDelegate?.checkForUnusedPodcasts()
        ServerConfig.shared.syncDelegate?.cleanupAllUnusedEpisodeBuffers()

        UserDefaults.standard.set(Date(), forKey: ServerConstants.UserDefaults.lastRefreshEndTime)

        FileLog.shared.addMessage("Refresh complete found \(newEpisodesAdded) new episodes")

        return (newEpisodesAdded > 0) ? .successNewData : .successNoNewData
    }

    private func cleanupAfterCancel() {
        // PodHopper: a cancelled refresh may have saved some episodes but not others, so its feed
        // validators are never saved, and the next refresh fetches those feeds in full.
        apiQueue.cancelAllOperations()
    }

    private func processAutoAddUpNextCandidates() {
        // look through our candidate episodes that are new and should be added to Up Next, and add any that haven't been played or archived as part of the sync
        let upNextLimit = ServerSettings.autoAddToUpNextLimit()

        let autoAddCandidates = DataManager.sharedManager.autoAddCandidates.candidates()

        if !autoAddCandidates.isEmpty {
            let startingCount = ServerConfig.shared.playbackDelegate?.upNextQueueCount() ?? 0
            FileLog.shared.addMessage("Checking for auto add to up next episodes in \(autoAddCandidates.count) podcasts that have been updated with auto add to up next turned on limit is \(upNextLimit) starting count is \(startingCount)")
        }

        for candidate in autoAddCandidates {
            // Ignore any podcasts that no longer have the setting enabled
            guard candidate.autoAddToUpNextSetting != .off else {
                continue
            }

            let episodeUuid = candidate.episodeUuid
            let toTop = candidate.autoAddToUpNextSetting == .addFirst

            guard let episode = DataManager.sharedManager.findEpisode(uuid: episodeUuid), !episode.played(), !episode.archived, let inUpNext = ServerConfig.shared.playbackDelegate?.inUpNext(episode: episode), inUpNext == false else { continue }

            let currentCount = ServerConfig.shared.playbackDelegate?.upNextQueueCount() ?? 0
            if currentCount < upNextLimit {
                FileLog.shared.addMessage("Current Up Next count \(currentCount) is less than the limit, adding \(episode.displayableTitle()) to the \(toTop ? "top" : "bottom") of Up Next")
                ServerConfig.shared.playbackDelegate?.addToUpNext(episode: episode, ignoringQueueLimit: false, toTop: toTop)
            } else if toTop, ServerSettings.onAutoAddLimitReached() == .addToTopOnly {
                FileLog.shared.addMessage("Current Up Next count \(currentCount) is over the limit but still adding \(episode.displayableTitle()) to the top of the list")
                ServerConfig.shared.playbackDelegate?.removeLastEpisodeFromUpNext()
                ServerConfig.shared.playbackDelegate?.addToUpNext(episode: episode, ignoringQueueLimit: true, toTop: toTop)
            } else {
                FileLog.shared.addMessage("Current Up Next count \(currentCount) is over the limit not adding episode \(episode.displayableTitle())")
            }

            // The candidate has been processed, remove it from the database
            DataManager.sharedManager.autoAddCandidates.remove(candidate)
        }

        // We have finished processing all of the up next candidates.
        //
        // There is a chance that some candidates are invalid and were not processed. We'll solve this by deleting all
        // of the candidates from the DB to ensure there are no ghost episodes left over.
        DataManager.sharedManager.autoAddCandidates.clearAll()
    }
}
