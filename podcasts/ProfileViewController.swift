import PocketCastsDataModel
import PocketCastsServer
import PocketCastsUtils
import UIKit
import SwiftUI

class ProfileViewController: PCViewController, UITableViewDataSource, UITableViewDelegate {
    fileprivate enum StatValueType { case listened, saved }

    private var refreshController: FullSyncRefreshController?

    @IBOutlet var footerView: UIView!
    @IBOutlet var alertIcon: UIImageView!
    @IBOutlet var lastRefreshTime: ThemeableLabel! {
        didSet {
            lastRefreshTime.style = .primaryText02
            lastRefreshTime.font = UIFont.font(with: .subheadline, maxSizeCategory: .accessibilityMedium)
            lastRefreshTime.adjustsFontForContentSizeCategory = true
        }
    }
    @IBOutlet var refreshButtonContainer: UIView!

    private var refreshButtonTitle: String = L10n.refreshNow {
        didSet {
            updateRefreshButton()
        }
    }

    private var isRefreshAnimating: Bool = false {
        didSet {
            updateRefreshButton()
        }
    }

    private var refreshButtonHostingController: UIHostingController<AnyView>?

    private func setupRefreshButton() {
        updateRefreshButton()
        if let hostingController = refreshButtonHostingController {
            hostingController.sizingOptions = .intrinsicContentSize
            addChild(hostingController)
            refreshButtonContainer.addSubview(hostingController.view)
            hostingController.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                hostingController.view.topAnchor.constraint(equalTo: refreshButtonContainer.topAnchor),
                hostingController.view.bottomAnchor.constraint(equalTo: refreshButtonContainer.bottomAnchor),
                hostingController.view.centerXAnchor.constraint(equalTo: refreshButtonContainer.centerXAnchor),
                hostingController.view.leadingAnchor.constraint(greaterThanOrEqualTo: refreshButtonContainer.leadingAnchor),
                hostingController.view.trailingAnchor.constraint(lessThanOrEqualTo: refreshButtonContainer.trailingAnchor)
            ])
            hostingController.didMove(toParent: self)
        }
    }

    private func updateRefreshButton() {
        let refreshButton = ProfileRefreshButton(
            title: refreshButtonTitle,
            isAnimating: isRefreshAnimating,
            action: { [weak self] in
                self?.refreshTapped()
            }
        ).setupDefaultEnvironment()

        if let hostingController = refreshButtonHostingController {
            hostingController.rootView = AnyView(refreshButton)
        } else {
            let hostingController = UIHostingController(rootView: AnyView(refreshButton))
            hostingController.view.backgroundColor = .clear
            self.refreshButtonHostingController = hostingController
        }
    }

    @IBOutlet var plusInfoView: PlusLockedInfoView! {
        didSet {
            // PodHopper: the Pocket Casts Plus billboard is removed. Keep it always hidden. It is an
            // arranged subview of a vertical stack view, so hiding collapses it with no leftover gap.
            plusInfoView.isHidden = true
            plusInfoView.delegate = self
        }
    }

    var promoCode: String? {
        didSet {
            showPromotionViewController(promoCode: promoCode)
        }
    }

    var promoRedeemedMessage: String?
    private let settingsCellId = "SettingsCell"

    enum TableRow { case informationalBanner, allStats, downloaded, starred, listeningHistory, help, uploadedFiles, bookmarks }

    private lazy var informationalBannerCoordinator: InformationalBannerViewCoordinator = {
        let viewModel = InformationalBannerViewModel(bannerType: .profile)
        return InformationalBannerViewCoordinator(viewModel: viewModel)
    }()

    @IBOutlet var profileTable: UITableView! {
        didSet {
            profileTable.register(UINib(nibName: "TopLevelSettingsCell", bundle: nil), forCellReuseIdentifier: settingsCellId)
            profileTable.register(InformationalProfileBannerCell.self, forCellReuseIdentifier: InformationalProfileBannerCell.identifier)
        }
    }

    // MARK: - Profile Header
    private lazy var headerViewModel: ProfileHeaderViewModel = {
        let viewModel = ProfileHeaderViewModel(navigationController: navigationController)

        // Listen for view size changes and update the header view cell if needed
        viewModel.viewContentSizeChanged = { [weak self] in
            self?.profileTable.reloadData()
        }

        return viewModel
    }()

    private lazy var headerView: UIView = {
        let headerView = ProfileHeaderView(viewModel: headerViewModel)

        let view = headerView.themedUIView
        view.backgroundColor = .clear

        return view
    }()

    // MARK: - View Events

    override func viewDidLoad() {
        customRightBtn = UIBarButtonItem(image: UIImage(named: "profile-settings"), style: .plain, target: self, action: #selector(settingsTapped))
        customRightBtn?.accessibilityLabel = L10n.accessibilityProfileSettings
        customRightBtn?.accessibilityIdentifier = "Settings"

        super.viewDidLoad()
        navigationItem.title = L10n.profile

        profileTable.tableFooterView = footerView

        setupRefreshButton()
        updateDisplayedData()
        updateRefreshFooterColors()
        updateFooterFrame()
        setupRefreshControl()
        insetAdjuster.setupInsetAdjustmentsForMiniPlayer(scrollView: profileTable)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        updateDisplayedData()

        Analytics.track(.profileShown)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        addCustomObserver(ServerNotifications.podcastsRefreshed, selector: #selector(refreshComplete))
        addCustomObserver(Constants.Notifications.podcastAdded, selector: #selector(handleDataChangedNotification))
        addCustomObserver(Constants.Notifications.podcastDeleted, selector: #selector(handleDataChangedNotification))
        addCustomObserver(ServerNotifications.podcastRefreshFailed, selector: #selector(refreshComplete))
        addCustomObserver(ServerNotifications.podcastRefreshThrottled, selector: #selector(refreshComplete))
        addCustomObserver(ServerNotifications.syncCompleted, selector: #selector(refreshComplete))
        addCustomObserver(ServerNotifications.syncFailed, selector: #selector(refreshComplete))
        addCustomObserver(ServerNotifications.subscriptionStatusChanged, selector: #selector(handleDataChangedNotification))
        addCustomObserver(.userLoginDidChange, selector: #selector(handleDataChangedNotification))
        addCustomObserver(.serverUserWillBeSignedOut, selector: #selector(handleDataChangedNotification))
        addCustomObserver(.whatsNewDismissed, selector: #selector(whatsNewDismissed))

        addCustomObserver(Constants.Notifications.tappedOnSelectedTab, selector: #selector(checkForScrollTap(_:)))
        if promoRedeemedMessage != nil {
            updateDisplayedData()
            showPromotionRedeemedAcknowledgement()
            promoRedeemedMessage = nil
        }

        whatsNewDismissed()

        if FeatureFlag.cancelSubscriptionSurvey.enabled,
           SyncManager.isUserLoggedIn(),
           SubscriptionHelper.hasCancelledSubscription,
           !Settings.subscriptionCancelledSurveyShown {
            let controller = CancelSubscriptionSurveyViewModel.make()
            present(controller, animated: true)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        removeAllCustomObservers()
    }

    override func handleThemeChanged() {
        updateRefreshFooterColors()
    }

    private func updateRefreshFooterColors() {
        alertIcon.tintColor = ThemeColor.primaryIcon02()
    }

    // MARK: - Actions

    @objc private func checkForScrollTap(_ notification: Notification) {
        if let index = notification.object as? Int, index == tabBarItem.tag, profileTable.contentOffset.y > 0 {
            profileTable.setContentOffset(CGPoint.zero, animated: true)
        }
    }

    @objc private func settingsTapped() {
        Analytics.track(.profileSettingsButtonTapped)

        let settingsController = SettingsViewController()
        navigationController?.pushViewController(settingsController, animated: true)
    }

    private func showAccountController() {
        let accountVC = AccountViewController()
        navigationController?.pushViewController(accountVC, animated: true)
    }

    private func refreshTapped() {
        Analytics.track(.profileRefreshButtonTapped)

        isRefreshAnimating = true
        lastRefreshTime.text = L10n.refreshing
        RefreshManager.shared.refreshPodcasts()

        // PodHopper: also run PodHopper's cross-device sync so a manual refresh pulls the latest
        // playback positions and subscriptions from the user's other devices, not just new episodes.
        // These run in the background and no-op when signed out; the visible "refreshing" state
        // tracks the on-device feed refresh, which posts the completion that stops the spinner.
        PodHopperPositionSync.shared.pushCurrentPosition(immediate: true)
        PodHopperPositionSync.shared.pullLatestPositions(adoptCurrentEpisode: true)
        PodHopperSubscriptionSync.shared.pullSubscriptions()
    }

    // MARK: - Data Updates

    @objc private func refreshComplete() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            self.isRefreshAnimating = false
            self.updateLastRefreshDetails()
        }
    }

    @objc private func handleDataChangedNotification() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            self.updateDisplayedData()
        }
    }

    private func updateDisplayedData() {
        // Update the new header's data
        headerViewModel.update()

        updateLastRefreshDetails()
        // PodHopper: Pocket Casts Plus billboard removed, stays hidden.
        plusInfoView.isHidden = true
        updateFooterFrame()
        refreshTableData()
    }

    private func updateLastRefreshDetails() {
        navigationItem.leftBarButtonItem = nil

        // PodHopper: the status reflects PodHopper's on-device feed refresh only. The old
        // "sync failed" state came from Pocket Casts account sync, which PodHopper does not use, so
        // it is no longer checked here.
        if !ServerSettings.lastRefreshSucceeded() {
            lastRefreshTime.text = L10n.refreshFailed
            refreshButtonTitle = L10n.tryAgain
            alertIcon.isHidden = false
        } else if let lastUpdateTime = ServerSettings.lastRefreshEndTime() {
            refreshButtonTitle = L10n.refreshNow
            if abs(lastUpdateTime.timeIntervalSinceNow) > 2.days {
                lastRefreshTime.text = L10n.profileLastAppRefresh(TimeFormatter.shared.appleStyleElapsedString(date: lastUpdateTime))
                alertIcon.isHidden = false
            } else {
                lastRefreshTime.text = L10n.refreshPreviousRun(TimeFormatter.shared.appleStyleElapsedString(date: lastUpdateTime))
                alertIcon.isHidden = true
            }
        } else {
            refreshButtonTitle = L10n.refreshNow
            lastRefreshTime.text = L10n.refreshPreviousRun(L10n.timeFormatNever)
            alertIcon.isHidden = false
        }
    }

    // MARK: - UITableView

    func numberOfSections(in tableView: UITableView) -> Int {
        tableData.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        tableData[section].count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = tableData[indexPath.section][indexPath.row]

        if row == .informationalBanner {
            let cell = tableView.dequeueReusableCell(withIdentifier: InformationalProfileBannerCell.identifier, for: indexPath) as! InformationalProfileBannerCell
            cell.onCloseBannerTap = { [weak self] cell in
                if let cell, let indexPath = tableView.indexPath(for: cell) {
                    self?.tableData[indexPath.section].remove(at: indexPath.row)
                    tableView.deleteRows(at: [indexPath], with: .fade)
                }
            }
            return cell
        }

        let cell = tableView.dequeueReusableCell(withIdentifier: settingsCellId, for: indexPath) as! TopLevelSettingsCell

        cell.settingsImage.tintColor = ThemeColor.primaryIcon01()
        cell.settingsLabel.setLetterSpacing(-0.01)
        cell.separatorInset = .zero

        switch row {
        case .informationalBanner:
            return InformationalProfileBannerCell()
        case .allStats:
            cell.settingsImage.image = UIImage(named: "profile-stats")
            cell.settingsLabel.text = L10n.settingsStats
        case .downloaded:
            cell.settingsImage.image = UIImage(named: "profile-download")
            cell.settingsLabel.text = L10n.downloads
        case .uploadedFiles:
            cell.settingsImage.image = UIImage(named: "profile_files")
            cell.settingsLabel.text = L10n.files
        case .starred:
            cell.settingsImage.image = UIImage(named: "profile-star")
            cell.settingsLabel.text = L10n.statusStarred
        case .listeningHistory:
            cell.settingsImage.image = UIImage(named: "profile-history")
            cell.settingsLabel.text = L10n.listeningHistory
        case .help:
            cell.settingsImage.image = UIImage(named: "profile-help")
            cell.settingsLabel.text = L10n.settingsHelp
        case .bookmarks:
            cell.settingsImage.image = UIImage(named: "bookmarks-profile")
            cell.settingsLabel.text = L10n.bookmarks
        }

        return cell
    }

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        let row = tableData[indexPath.section][indexPath.row]
        return row != .informationalBanner
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        let row = tableData[indexPath.section][indexPath.row]
        switch row {
        case .informationalBanner:
            return 160
        default:
            return 70
        }
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        let row = tableData[indexPath.section][indexPath.row]
        navigateToRow(row)
    }

    func navigateToRow(_ row: TableRow) {
        switch row {
        case .informationalBanner:
            break
        case .allStats:
            let statsViewController = StatsViewController()
            navigationController?.pushViewController(statsViewController, animated: true)
        case .downloaded:
            let downloadController = DownloadsViewController()
            navigationController?.pushViewController(downloadController, animated: true)
        case .uploadedFiles:
            let uploadedController = UploadedViewController()
            navigationController?.pushViewController(uploadedController, animated: true)
        case .starred:
            let starredController = StarredViewController()
            navigationController?.pushViewController(starredController, animated: true)
        case .listeningHistory:
            let historyController = ListeningHistoryViewController()
            navigationController?.pushViewController(historyController, animated: true)
        case .help:
            dismiss(animated: true)
            let navController = SJUIUtils.navController(for: PodHopperHelpHostingController())
            present(navController, animated: true, completion: nil)
        case .bookmarks:
            let bookmarksController = BookmarksProfileListController()
            navigationController?.pushViewController(bookmarksController, animated: true)
        }
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        18
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        headerView
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return headerViewModel.contentSize?.height ?? UITableView.automaticDimension
    }

    private var tableData: [[ProfileViewController.TableRow]] = []

    private func refreshTableData() {
        var data: [[ProfileViewController.TableRow]]
        data = [[.allStats, .downloaded, .uploadedFiles, .starred, .bookmarks, .listeningHistory, .help]]

        if informationalBannerCoordinator.shouldShowBanner() {
            data[0].insert(.informationalBanner, at: 0)
        }

        tableData = data
        profileTable.reloadData()
    }

    private func updateFooterFrame() {
        footerView.setNeedsLayout()
        footerView.layoutIfNeeded()

        let targetSize = CGSize(width: profileTable.bounds.width, height: UIView.layoutFittingCompressedSize.height)
        let height = footerView.systemLayoutSizeFitting(targetSize, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height

        footerView.frame = CGRect(x: footerView.frame.minX, y: footerView.frame.minY, width: footerView.frame.width, height: height)
        profileTable.tableFooterView = footerView
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        if traitCollection.preferredContentSizeCategory != previousTraitCollection?.preferredContentSizeCategory {
            updateFooterFrame()
        }
    }

    // MARK: - What's New Autoplay flow

    @objc private func whatsNewDismissed() {
        showGeneralSettingsIfNeeded()
        showHeadphoneControlsFromWhatsNew()
    }

    private func showGeneralSettingsIfNeeded() {
        if AnnouncementFlow.current == .autoPlay {
            let generalSettingsViewController = GeneralSettingsViewController()
            navigationController?.pushViewController(generalSettingsViewController, animated: true)
        }
    }

    // Pushes to the headphone controls if shown from the what's new
    private func showHeadphoneControlsFromWhatsNew() {
        guard AnnouncementFlow.current == .bookmarksProfile else { return }

        let controller = HeadphoneSettingsViewController()
        navigationController?.pushViewController(controller, animated: true)
        AnnouncementFlow.current = .none
    }

}

extension ProfileViewController: UIPopoverPresentationControllerDelegate {
    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
        // Return no adaptive presentation style, use default presentation behaviour
        return .none
    }
}
// MARK: - PlusLockedInfoDelegate

extension ProfileViewController: PlusLockedInfoDelegate {
    func closeInfoTapped() {
        Settings.setPlusInfoDismissedOnProfile(true)
        plusInfoView.isHidden = true
        updateFooterFrame()
    }

    var displayingViewController: UIViewController {
        self
    }

    var displaySource: PlusUpgradeViewSource {
        .profile
    }
}

// MARK: - Refresh Control

extension ProfileViewController {
    private func setupRefreshControl() {
        let controller = FullSyncRefreshController(source: .profile)
        refreshController = controller
        profileTable.refreshControl = controller.refreshControl
    }
}
