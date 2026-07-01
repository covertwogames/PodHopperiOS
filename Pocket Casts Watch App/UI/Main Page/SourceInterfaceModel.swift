import Combine
import PocketCastsServer
import PocketCastsUtils
import WatchKit

class SourceInterfaceModel: ObservableObject {

    @Published var activeSource: Source = .phone

    @Published var lastRefreshLabel: String = L10n.profileLastAppRefresh(L10n.timeFormatNever)

    @Published var isLoggedIn: Bool = false

    @Published var profileImage: String = "profile-free"

    @Published var usernameLabel: String = L10n.signedOut

    private var refreshTimedActionHelper = TimedActionHelper()

    private var cancellables = Set<AnyCancellable>()

    func willActivate() {
        addObservers()
        reload()
        handleDataUpdated()
    }

    func handleDataUpdated() {
        guard !refreshTimedActionHelper.isTimerValid() else {
            refreshTimedActionHelper.cancelTimer()
            RefreshManager.shared.refreshPodcasts(forceEvenIfRefreshedRecently: false)
            return
        }
        reload()
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: WatchConstants.Notifications.dataUpdated, object: nil)
        removeAllCustomObservers()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Notifications For Updates

    @objc private func dataDidUpdate() {
        DispatchQueue.main.async {
            self.handleDataUpdated()
        }
    }

    private var customObservers = [Notification.Name]()

    func addCustomObserver(_ name: Notification.Name, selector: Selector) {
        if containsObserver(name) { return } // we already have this one

        customObservers.append(name)

        NotificationCenter.default.addObserver(self, selector: selector, name: name, object: nil)
    }

    func removeAllCustomObservers() {
        if customObservers.isEmpty { return }

        let notCenter = NotificationCenter.default
        for name in customObservers {
            notCenter.removeObserver(self, name: name, object: nil)
        }
        customObservers.removeAll()
    }

    private func containsObserver(_ name: Notification.Name) -> Bool {
        if customObservers.isEmpty { return false }

        return customObservers.contains(name)
    }

    func addObservers() {
        addCustomObserver(WatchConstants.Notifications.dataUpdated, selector: #selector(dataDidUpdate))
        addCustomObserver(ServerNotifications.syncFailed, selector: #selector(updateLastRefreshDetails))
        addCustomObserver(ServerNotifications.syncStarted, selector: #selector(updateLastRefreshDetails))
        addCustomObserver(ServerNotifications.syncCompleted, selector: #selector(updateLastRefreshDetails))

        // PodHopper login state drives the screen: signed in unlocks the Watch source.
        PodHopperSupabaseClient.shared.loginState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reload()
            }
            .store(in: &cancellables)
    }

    private func reload() {
        isLoggedIn = PodHopperSupabaseClient.shared.isLoggedIn()
        activeSource = SourceManager.shared.currentSource()

        if isLoggedIn {
            usernameLabel = PodHopperSupabaseClient.shared.signedInEmail ?? ""
            profileImage = "profile-plus"
            updateLastRefreshDetails()
        } else {
            usernameLabel = L10n.signedOut
            profileImage = "profile-free"
        }
    }

    func phoneTapped() {
        if SourceManager.shared.isWatch(), !nowPlayingEpisodesMatchOnBothSources() {
            WatchSyncManager.shared.syncThenNotifyPhone(significantChange: true, syncRequired: true)
        }

        SourceManager.shared.setSource(newSource: .phone)
    }

    func watchTapped() {
        guard PodHopperSupabaseClient.shared.isLoggedIn() else { return }

        if SourceManager.shared.isPhone(), !nowPlayingEpisodesMatchOnBothSources() {
            RefreshManager.shared.refreshPodcasts(forceEvenIfRefreshedRecently: false)
        }
        SourceManager.shared.setSource(newSource: .watch)
    }

    private func nowPlayingEpisodesMatchOnBothSources() -> Bool {
        let watchCurrentEpisode = PlaybackManager.shared.currentEpisode()
        let phoneCurrentEpisode = WatchDataManager.playingEpisode()
        if watchCurrentEpisode?.uuid == phoneCurrentEpisode?.uuid {
            if watchCurrentEpisode?.playedUpTo == phoneCurrentEpisode?.playedUpTo {
                return true
            }
        }
        return false
    }

    func refreshDataTapped() {
        WKInterfaceDevice.current().play(.success)
        SessionManager.shared.requestData()

        refreshTimedActionHelper.startTimer(for: 5.seconds, action: {
            RefreshManager.shared.refreshPodcasts(forceEvenIfRefreshedRecently: true)
        })

        lastRefreshLabel = L10n.refreshing
    }

    func logout() {
        WKInterfaceDevice.current().play(.success)
        PodHopperSubscriptionSync.shared.stopPeriodicSync()
        PodHopperSupabaseClient.shared.logout()
        SourceManager.shared.setSource(newSource: .phone)
        reload()
    }

    @objc private func updateLastRefreshDetails() {
        var lastRefreshText = String()
        if !ServerSettings.lastRefreshSucceeded() {
            lastRefreshText = L10n.refreshFailed
        } else if SyncManager.isRefreshInProgress() {
            lastRefreshText = L10n.refreshing
        } else if let lastUpdateTime = ServerSettings.lastRefreshEndTime() {
            lastRefreshText = L10n.refreshPreviousRun(TimeFormatter.shared.appleStyleElapsedString(date: lastUpdateTime))
        } else {
            lastRefreshText = L10n.timeFormatNever
        }

        DispatchQueue.main.async { [weak self] in
            self?.lastRefreshLabel = lastRefreshText
        }
    }
}
