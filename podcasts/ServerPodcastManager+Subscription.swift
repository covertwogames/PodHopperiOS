import PocketCastsServer
import PocketCastsUtils
import PocketCastsDataModel

extension ServerPodcastManager {

    func subscribe(to podcastUuid: String, completion: ((Bool) -> ())?) {
        let limits = Settings.autoDownloadEnabled() && FeatureFlag.autoDownloadOnSubscribe.enabled && Settings.autoDownloadOnFollow() ? Settings.autoDownloadLimits().rawValue : 0
        self.addFromUuid(podcastUuid: podcastUuid, subscribe: true, autoDownloads: limits) { added in
            if added {
                ServerPodcastManager.fillEpisodesIfNeeded(podcastUuid: podcastUuid)
            }
            completion?(added)
        }
    }

    func subscribeFromItunesId(_ itunesId: Int, completion: ((Bool, String?) -> ())?) {
        let limits = Settings.autoDownloadEnabled() && FeatureFlag.autoDownloadOnSubscribe.enabled && Settings.autoDownloadOnFollow() ? Settings.autoDownloadLimits().rawValue : 0
        self.addFromiTunesId(itunesId, subscribe: true, autoDownloads: limits) { added, podcastUuid in
            if added, let podcastUuid {
                ServerPodcastManager.fillEpisodesIfNeeded(podcastUuid: podcastUuid)
            }
            completion?(added, podcastUuid)
        }
    }

    /// PodHopper: a podcast subscribed to from a search or discover result is a stub with no episodes
    /// until its page is opened. Fetch them now, the way opening the page does, rather than leaving the
    /// show empty until the next refresh, and let an open page know when they land.
    private static func fillEpisodesIfNeeded(podcastUuid: String) {
        Task.detached {
            PodHopperFeedManager.shared.fillEpisodesIfNeeded(podcastUuid: podcastUuid)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Constants.Notifications.podcastUpdated, object: podcastUuid)
            }
        }
    }
}
