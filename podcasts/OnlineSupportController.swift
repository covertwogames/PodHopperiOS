import MessageUI
import SwiftUI
import PocketCastsServer
import UIKit
import WebKit

class OnlineSupportController: PCViewController, WKNavigationDelegate, UIAdaptivePresentationControllerDelegate {
    enum Source: String {
        case settings
        case winback
        case about
    }

    private let loadingIndicator = AngularActivityIndicator(size: CGSize(width: 40, height: 40), lineWidth: 2.0, duration: 1.0)

    private var supportWebView = WKWebView()
    private let source: Source

    var didDismiss: (() -> Void)? = nil

    var request: URLRequest

    init(url: URL = ServerHelper.asUrl(ServerConstants.Urls.support), source: Source = .settings) {
        request = URLRequest(url: url)
        self.source = source
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .white

        presentationController?.delegate = self
        navigationController?.presentationController?.delegate = self

        title = L10n.settingsHelp

        // A temporary workaround until the web supports safe area.
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationItem.compactAppearance = appearance

        setupLoadingIndicator()
        setupWebView()

        loadingIndicator.startAnimating()
        load()

        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: UIBarButtonItem.SystemItem.close, target: self, action: #selector(doneTapped))

        // PodHopper: no "..." menu here. Its connection status page checked servers PodHopper does
        // not use, and these pages only show PodHopper's legal text.

        AnalyticsHelper.userGuideOpened()

        switch source {
        case .winback:
            Analytics.track(.winbackScreenShown, properties: ["screen": "help_and_feedback"])
        default:
            Analytics.track(.settingsHelpShown)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        switch source {
        case .winback:
            Analytics.track(.winbackScreenDismissed, properties: ["screen": "help_and_feedback"])
        default:
            break
        }
    }

    private func setupLoadingIndicator() {
        loadingIndicator.color = AppTheme.loadingActivityColor()
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loadingIndicator)
        NSLayoutConstraint.activate([
            loadingIndicator.widthAnchor.constraint(equalToConstant: 40),
            loadingIndicator.heightAnchor.constraint(equalToConstant: 40),
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40)
        ])
    }

    private func setupWebView() {
        view.insertSubview(supportWebView, belowSubview: loadingIndicator)
        supportWebView.anchorToAllSidesOf(view: view)

        supportWebView.navigationDelegate = self

        supportWebView.backgroundColor = UIColor.white
        supportWebView.scrollView.backgroundColor = UIColor.white
    }

    deinit {
        supportWebView.navigationDelegate = nil
    }

    @objc private func doneTapped() {
        dismiss(animated: true, completion: didDismiss)
    }

    private func load() {
        supportWebView.load(request)
    }

    override func contentScrollView(for edge: NSDirectionalRectEdge) -> UIScrollView? {
        supportWebView.scrollView
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, url.scheme?.lowercased() == "mailto" {
            // PodHopper: an email link on a page shown here (the privacy policy and terms) opens Mail
            // addressed as the link intends. This used to open the Pocket Casts support form instead.
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadingIndicator.stopAnimating()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadingIndicator.stopAnimating()
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .portrait // since this controller is presented modally it needs to tell iOS it only goes portrait
    }

    // MARK: - UIAdaptivePresentationControllerDelegate

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        didDismiss?()
    }
}
