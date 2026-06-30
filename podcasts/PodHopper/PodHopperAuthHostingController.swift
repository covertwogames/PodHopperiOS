import SwiftUI

/// Presents PodHopper's auth/account screen. Shows the account view (email + logout) when signed in
/// and the login flow when signed out. Dismisses on successful sign-in, on logout, and on close.
class PodHopperAuthHostingController: ThemedHostingController<PodHopperAuthRootView> {
    private let viewModel: PodHopperAuthViewModel
    private let onFinished: (() -> Void)?

    init(onFinished: (() -> Void)? = nil) {
        let viewModel = PodHopperAuthViewModel()
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
