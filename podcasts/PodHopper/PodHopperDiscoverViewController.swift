import Foundation
import PocketCastsDataModel
import PocketCastsServer
import SwiftUI
import UIKit

/// Backs the PodHopper Discover landing and its full grid. Loads the iTunes top podcasts chart for
/// the device country and, when a tile is tapped, resolves that chart entry to its real RSS feed
/// url, adds it as a not subscribed podcast, and opens the real podcast page so it can be played
/// without following it. UIKit navigation is performed by the hosting controller through the action
/// hooks, so this type stays free of view controller plumbing.
@MainActor
final class PodHopperDiscoverViewModel: ObservableObject {
    enum LoadState {
        case loading
        case error
        case loaded([PodHopperTopListLoader.TopPodcast])
    }

    @Published var state: LoadState = .loading

    var onOpenPodcast: ((String) -> Void)?
    var onResolveFailed: (() -> Void)?
    var onSearchBarTap: (() -> Void)?
    var onDiscoverMore: (() -> Void)?
    var onAddByUrl: (() -> Void)?

    private let loader: PodHopperTopListLoader
    private var limit = PodHopperDiscoverViewModel.suggestionsLimit

    init(loader: PodHopperTopListLoader = .shared) {
        self.loader = loader
    }

    func load(limit: Int) {
        self.limit = limit
        state = .loading
        Task {
            let list = await loader.loadTopList(country: deviceCountry(), limit: limit)
            state = list.isEmpty ? .error : .loaded(list)
        }
    }

    func retry() {
        load(limit: limit)
    }

    func tileTapped(_ item: PodHopperTopListLoader.TopPodcast) {
        Task {
            let feedUrl = await loader.resolveFeedUrl(item.lookupUrl)
            guard let feedUrl, feedUrl.isEmpty == false else {
                onResolveFailed?()
                return
            }
            let uuid = await Task.detached {
                PodHopperFeedManager.shared.addFeedUrlStub(
                    feedUrl: feedUrl,
                    title: item.title,
                    author: item.author,
                    imageURL: item.imageUrl
                )
            }.value
            onOpenPodcast?(uuid)
            Task.detached {
                PodHopperFeedManager.shared.fillFeedUrlEpisodes(feedUrl)
            }
        }
    }

    /// Adds a pasted RSS url as a not subscribed podcast and returns its uuid, or nil if the feed
    /// could not be parsed. Parses up front off the main thread, so the caller shows a spinner.
    func addByUrl(_ feedUrl: String) async -> String? {
        await Task.detached {
            PodHopperFeedManager.shared.addFeedUrlAsUnsubscribed(feedUrl)
        }.value
    }

    private func deviceCountry() -> String {
        let code: String?
        if #available(iOS 16, *) {
            code = Locale.current.region?.identifier
        } else {
            code = Locale.current.regionCode
        }
        let country = code ?? "US"
        return country.isEmpty ? "US" : country
    }

    static let suggestionsLimit = 12
    static let fullLimit = 40
}

/// The Discover tab. In landing mode it shows a search bar, a suggestions grid from the iTunes top
/// list, a Discover more link to the full grid, and an add by RSS url row. In full grid mode it
/// shows the larger grid on its own pushed screen. Tapping a tile resolves its real feed url, adds
/// it as a not subscribed podcast, and opens the real podcast page; the search bar opens the
/// existing remote search.
final class PodHopperDiscoverViewController: ThemedHostingController<PodHopperDiscoverView> {
    private let viewModel: PodHopperDiscoverViewModel
    private let mode: PodHopperDiscoverMode

    init(mode: PodHopperDiscoverMode) {
        let viewModel = PodHopperDiscoverViewModel()
        self.viewModel = viewModel
        self.mode = mode
        super.init(rootView: PodHopperDiscoverView(viewModel: viewModel, mode: mode))

        viewModel.onSearchBarTap = { [weak self] in
            self?.openSearch()
        }
        viewModel.onDiscoverMore = { [weak self] in
            self?.openFullGrid()
        }
        viewModel.onAddByUrl = { [weak self] in
            self?.showAddByUrlDialog()
        }
        viewModel.onOpenPodcast = { [weak self] uuid in
            self?.openPodcast(uuid: uuid)
        }
        viewModel.onResolveFailed = { [weak self] in
            self?.showResolveFailed()
        }
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        viewModel.load(limit: mode == .fullGrid ? PodHopperDiscoverViewModel.fullLimit : PodHopperDiscoverViewModel.suggestionsLimit)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if mode == .fullGrid {
            title = L10n.discover
            navigationController?.setNavigationBarHidden(false, animated: animated)
        } else {
            navigationController?.setNavigationBarHidden(true, animated: animated)
        }
    }

    private func openSearch() {
        navigationController?.pushViewController(PodHopperDiscoverSearchViewController(), animated: true)
    }

    private func openFullGrid() {
        navigationController?.pushViewController(PodHopperDiscoverViewController(mode: .fullGrid), animated: true)
    }

    private func openPodcast(uuid: String) {
        guard let podcast = DataManager.sharedManager.findPodcast(uuid: uuid, includeUnsubscribed: true) else {
            showResolveFailed()
            return
        }
        (view.window?.rootViewController as? MainTabBarController)?.navigateToPodcast(podcast)
    }

    private func showResolveFailed() {
        let alert = UIAlertController(title: nil, message: "Could not open this podcast.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.ok, style: .default))
        present(alert, animated: true)
    }

    private func showAddByUrlDialog() {
        let alert = UIAlertController(title: "Add podcast by RSS address", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "https://example.com/feed.xml"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: L10n.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self] _ in
            let url = (alert.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespaces)
            self?.addByUrl(url)
        })
        present(alert, animated: true)
    }

    private func addByUrl(_ url: String) {
        let lower = url.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else {
            showResolveFailed()
            return
        }
        let progress = UIAlertController(title: nil, message: "Loading...", preferredStyle: .alert)
        present(progress, animated: true)
        Task {
            let uuid = await viewModel.addByUrl(url)
            progress.dismiss(animated: true) { [weak self] in
                guard let uuid else {
                    self?.showResolveFailed()
                    return
                }
                self?.openPodcast(uuid: uuid)
            }
        }
    }
}

/// The remote podcast search screen reached from the Discover landing search bar. Pairs the shared
/// `PCSearchBarController` with the existing `SearchResultsViewController`, mirroring how the old
/// Pocket Casts Discover page wired search, but as a standalone pushed screen with the bar pinned
/// open and focused.
final class PodHopperDiscoverSearchViewController: UIViewController {
    private lazy var searchController = PCSearchBarController()
    private lazy var searchResultsController = SearchResultsViewController(source: .discover, showLocalResults: false)

    private var resultsControllerDelegate: SearchResultsDelegate {
        searchResultsController
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ThemeColor.primaryUi04()
        title = L10n.discover
        searchController.install(in: self, attachedTo: nil, collapses: false)
        searchController.searchDebounce = Settings.podcastSearchDebounceTime()
        searchController.searchDelegate = self
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        searchController.viewDidAppear(animated)
        searchController.searchTextField.becomeFirstResponder()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        searchController.viewDidDisappear(animated)
    }
}

extension PodHopperDiscoverSearchViewController: PCSearchBarDelegate {
    func searchDidBegin() {
        guard let searchView = searchResultsController.view, searchView.superview == nil else {
            return
        }
        searchView.alpha = 0
        addChild(searchResultsController)
        searchResultsController.beginAppearanceTransition(true, animated: false)
        view.addSubview(searchView)
        searchResultsController.didMove(toParent: self)

        searchView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            searchView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            searchView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            searchView.topAnchor.constraint(equalTo: searchController.view.bottomAnchor)
        ])

        UIView.animate(withDuration: Constants.Animation.defaultAnimationTime) {
            searchView.alpha = 1
        }
        searchResultsController.endAppearanceTransition()
        searchResultsController.searchShown()
    }

    func searchDidEnd() {
        guard let searchView = searchResultsController.view else { return }
        searchResultsController.beginAppearanceTransition(false, animated: false)
        UIView.animate(withDuration: Constants.Animation.defaultAnimationTime, animations: {
            searchView.alpha = 0
        }) { _ in
            searchView.removeFromSuperview()
            self.searchResultsController.endAppearanceTransition()
            self.resultsControllerDelegate.clearSearch()
        }
        searchResultsController.searchDismissed()
    }

    func searchWasCleared() {
        resultsControllerDelegate.clearSearch()
    }

    func searchTermChanged(_ searchTerm: String) {}

    func performSearch(searchTerm: String, triggeredByTimer: Bool, completion: @escaping (() -> Void)) {
        resultsControllerDelegate.performSearch(searchTerm: searchTerm, triggeredByTimer: triggeredByTimer, completion: completion)
    }
}
