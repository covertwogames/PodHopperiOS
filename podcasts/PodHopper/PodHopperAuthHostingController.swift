import SwiftUI

/// Presents PodHopper's auth/account screen. Shows the account view (email + logout) when signed in
/// and the login flow when signed out. Dismisses on successful sign-in, on logout, and on close.
class PodHopperAuthHostingController: ThemedHostingController<PodHopperAuthRootView> {
    private let viewModel: PodHopperAuthViewModel

    init() {
        let viewModel = PodHopperAuthViewModel()
        self.viewModel = viewModel
        super.init(rootView: PodHopperAuthRootView(viewModel: viewModel))

        viewModel.onAuthenticated = { [weak self] in
            self?.dismiss(animated: true)
        }
        viewModel.onClose = { [weak self] in
            self?.dismiss(animated: true)
        }
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
