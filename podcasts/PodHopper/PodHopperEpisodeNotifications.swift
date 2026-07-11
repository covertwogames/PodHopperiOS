import Foundation
import PocketCastsDataModel
import PocketCastsServer
import PocketCastsUtils
import UserNotifications

/// PodHopper: local new episode notifications. Pocket Casts delivered these as pushes from its
/// servers; PodHopper refreshes feeds on device, so after each refresh this checks podcasts with
/// notifications turned on and posts a local notification for any episode added since the last
/// check. Taps and notification actions are handled by the existing NotificationsHelper machinery.
class PodHopperEpisodeNotifications {
    static let shared = PodHopperEpisodeNotifications()

    private let lastCheckKey = "PodHopperLastEpisodeNotificationCheck"
    private let maxNotificationsPerRefresh = 5

    func setup() {
        NotificationCenter.default.addObserver(self, selector: #selector(refreshCompleted), name: ServerNotifications.podcastsRefreshed, object: nil)
        if UserDefaults.standard.object(forKey: lastCheckKey) == nil {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
        }
    }

    @objc private func refreshCompleted() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.checkForNewEpisodes()
        }
    }

    private func checkForNewEpisodes() {
        guard NotificationsHelper.shared.pushEnabled() else { return }

        let lastCheck = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: lastCheckKey))
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)

        let podcasts = DataManager.sharedManager.allPodcasts(includeUnsubscribed: false).filter { $0.pushEnabled }
        guard podcasts.isEmpty == false else { return }

        var toNotify: [(podcast: Podcast, episode: Episode)] = []
        for podcast in podcasts {
            let recent = DataManager.sharedManager.findEpisodesWhere(customWhere: "podcastUuid = ? ORDER BY addedDate DESC LIMIT 5", arguments: [podcast.uuid])
            for episode in recent {
                if let added = episode.addedDate, added > lastCheck {
                    toNotify.append((podcast, episode))
                }
            }
        }

        for item in toNotify.prefix(maxNotificationsPerRefresh) {
            let content = UNMutableNotificationContent()
            content.title = item.podcast.title ?? ""
            content.body = item.episode.title ?? ""
            content.sound = .default
            content.categoryIdentifier = NotificationsHelper.NotificationsCategory.episodes.rawValue
            content.userInfo = ["eu": item.episode.uuid, "podcast_uuid": item.podcast.uuid]
            content.threadIdentifier = item.podcast.uuid

            let request = UNNotificationRequest(identifier: "podhopper_ep_\(item.episode.uuid)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }

        if toNotify.isEmpty == false {
            FileLog.shared.addMessage("PodHopper: posted \(min(toNotify.count, maxNotificationsPerRefresh)) new episode notification(s)")
        }
    }
}
