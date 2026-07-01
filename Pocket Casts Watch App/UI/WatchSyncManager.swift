import Foundation
import PocketCastsDataModel
import PocketCastsServer
import PocketCastsUtils
import WatchKit

class WatchSyncManager {
    static let shared = WatchSyncManager()
    static let watchMinTimeBetweenPeriodicRefreshes = 15.minutes

    init() {
        NotificationCenter.default.addObserver(self, selector: #selector(syncCompleted), name: ServerNotifications.syncCompleted, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(significantEpisodeChangeMade), name: Constants.Notifications.episodePlayStatusChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(significantEpisodeChangeMade), name: Constants.Notifications.episodeArchiveStatusChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(minorEpisodeChangeMade), name: Constants.Notifications.episodeDurationChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(significantEpisodeChangeMade), name: Constants.Notifications.episodeStarredChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleContextUpdate), name: WatchConstants.Notifications.dataUpdated, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func setup() {
        let defaults = UserDefaults.standard

        // check to see that this app has a unique ID, if not create one
        let uniqueId = defaults.string(forKey: Constants.UserDefaults.appId)
        if uniqueId?.count ?? 0 < 1 {
            let uuid = UUID().uuidString
            defaults.set(uuid, forKey: Constants.UserDefaults.appId)
            defaults.synchronize()
        }

        ServerConfig.shared.syncDelegate = self
        ServerConfig.shared.playbackDelegate = PlaybackManager.shared

        performUpdateIfRequired(updateKey: "CreatedDefPlaylistsV2") {
            PlaylistManager.createDefaultPlaylists()
        }

        performUpdateIfRequired(updateKey: "FirstRunDefaults") {
            // these are considered defaults for a new app install
            ServerSettings.setSkipBackTime(10, syncChange: false)
            ServerSettings.setSkipForwardTime(45, syncChange: false)

            Settings.setAutoArchivePlayedAfter(0)
            Settings.setAutoArchiveInactiveAfter(-1)
            Settings.setArchiveStarredEpisodes(false)

            Settings.setShouldDeleteWhenPlayed(true)
            Settings.setMobileDataAllowed(true)
        }

        UserEpisodeManager.removeOrphanedUserEpisodes()
        Task {
            await DownloadManager.shared.clearStuckDownloads()
        }
    }

    private func performUpdateIfRequired(updateKey: String, update: () -> Void) {
        if UserDefaults.standard.bool(forKey: updateKey) { return } // already performed this update

        update()
        UserDefaults.standard.set(true, forKey: updateKey)
    }

    private lazy var contextUpdateDebouncer = ContextUpdateDebouncer(interval: 2.0) { [weak self] in
        self?.processContextUpdate()
    }

    @objc func handleContextUpdate() {
        if FeatureFlag.watchUpNextSyncFix.enabled,
           WKApplication.shared().applicationState != .background {
            // Debounce context updates so the watch fully processes the phone's changes before
            // deciding whether to sync. Only debounce in the foreground; in the background the
            // system execution window is tied to setTaskCompletedWithSnapshot, so process at once.
            contextUpdateDebouncer.call()
        } else {
            processContextUpdate()
        }
    }

    private func processContextUpdate() {
        // PodHopper signs in by pairing to Supabase and refreshes feeds on-device, so there is no
        // Pocket Casts background sync or phone credential handoff here.
        if isPlusUser() {
            periodicRefresh()
        }
        updatePodcastSettings()
    }

    func loginAndRefreshIfRequired() {
        // PodHopper: when signed in via pairing, pull the latest library from Supabase and refresh
        // feeds on-device. No Pocket Casts login or subscription check.
        guard isPlusUser() else { return }

        PodHopperSubscriptionSync.shared.pollSubscriptions()
        periodicRefresh()
    }

    @objc func handleUpdateFromPhone() {
        updatePodcastSettings()
    }

    private func periodicRefresh() {
        if DateUtil.hasEnoughTimePassed(since: ServerSettings.lastRefreshEndTime(), time: WatchSyncManager.watchMinTimeBetweenPeriodicRefreshes) {
            FileLog.shared.addMessage("Periodic Refresh - Starting")
            RefreshManager.shared.refreshPodcasts(forceEvenIfRefreshedRecently: false)
        }
    }

    func updatePodcastSettings() {
        guard isPlusUser(), let data = UserDefaults.standard.object(forKey: WatchConstants.UserDefaults.data) as? [String: Any] else { return }

        if let autoArchivePlayedAfter = data[WatchConstants.Keys.autoArchivePlayedAfter] as? TimeInterval {
            Settings.setAutoArchivePlayedAfter(autoArchivePlayedAfter)
        }

        if let autoArchiveStarred = data[WatchConstants.Keys.autoArchiveStarredEpisodes] as? Bool {
            Settings.setArchiveStarredEpisodes(autoArchiveStarred)
        }

        guard let podcastSettings = data[WatchConstants.Keys.podcastSettings] as? [[String: Any]] else { return }

        for podcastSetting in podcastSettings {
            guard let podcastUuid = podcastSetting[WatchConstants.Keys.podcastUuid] as? String, let podcast = DataManager.sharedManager.findPodcast(uuid: podcastUuid) else { continue }

            if let overrideGlobalArchive = podcastSetting[WatchConstants.Keys.podcastOverrideGlobalArchive] as? Bool {
                podcast.isAutoArchiveOverridden = overrideGlobalArchive
            }

            if let autoArchivePlayedAfter = podcastSetting[WatchConstants.Keys.podcastAutoArchivePlayedAfter] as? TimeInterval {
                podcast.autoArchivePlayedAfterTime = autoArchivePlayedAfter
            }
            DataManager.sharedManager.save(podcast: podcast)
        }
    }

    // MARK: - Change Notifications

    private enum ChangeNotification {
        case significant, minor, none
    }

    private var pendingChangeNotification = ChangeNotification.none
    func syncThenNotifyPhone(significantChange: Bool, syncRequired: Bool) {
        if significantChange {
            pendingChangeNotification = .significant
        } else if pendingChangeNotification == .none {
            pendingChangeNotification = .minor
        }

        if syncRequired {
            RefreshManager.shared.refreshPodcasts()
        } else {
            sendPendingChangeMessage()
        }
    }

    @objc private func significantEpisodeChangeMade() {
        syncThenNotifyPhone(significantChange: true, syncRequired: true)
    }

    @objc private func minorEpisodeChangeMade() {
        syncThenNotifyPhone(significantChange: false, syncRequired: true)
    }

    @objc private func syncCompleted() {
        checkForUpNextAutoDownloads()
        sendPendingChangeMessage()
    }

    private func sendPendingChangeMessage() {
        if pendingChangeNotification == .significant {
            SessionManager.shared.significantSyncableUpdate()
        } else if pendingChangeNotification == .minor {
            SessionManager.shared.minorSyncableUpdate()
        }

        pendingChangeNotification = .none
    }

    func isPlusUser() -> Bool {
        PodHopperSupabaseClient.shared.isLoggedIn()
    }
}
