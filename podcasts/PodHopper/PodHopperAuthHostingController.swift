import SwiftUI

/// Presents PodHopper's auth/account screen. Shows the account view (email + logout) when signed in
/// and the login flow when signed out. Dismisses on successful sign-in, on logout, and on close.
class PodHopperAuthHostingController: ThemedHostingController<PodHopperAuthRootView> {
    private let viewModel: PodHopperAuthViewModel
    private let onFinished: (() -> Void)?

    /// `signedOutNotice`: PodHopper opens the Log in screen by itself once when this device was signed
    /// out without the person choosing it (a new device restored from a backup, an expired sign-in, or
    /// removed from the list on another device). The screen then says so at the top.
    init(onFinished: (() -> Void)? = nil, signedOutNotice: Bool = false) {
        let viewModel = PodHopperAuthViewModel()
        if signedOutNotice {
            viewModel.notice = "You've been signed out on this device. Log in to keep syncing."
        }
        self.viewModel = viewModel
        self.onFinished = onFinished
        super.init(rootView: PodHopperAuthRootView(viewModel: viewModel))

        viewModel.onAuthenticated = { [weak self] in
            guard let self else { return }
            let finished = self.onFinished
            self.dismiss(animated: true) {
                finished?()
            }
        }
        viewModel.onClose = { [weak self] in
            guard let self else { return }
            let finished = self.onFinished
            self.dismiss(animated: true) {
                finished?()
            }
        }
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
