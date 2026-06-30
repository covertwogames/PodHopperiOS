import SwiftUI

/// Presents PodHopper's first-run onboarding full screen, replacing the old Pocket Casts intro,
/// interests, and recommendations onboarding. Dismisses itself when the user finishes.
class PodHopperOnboardingHostingController: ThemedHostingController<PodHopperOnboardingRootView> {
    init() {
        let finisher = PodHopperOnboardingFinisher()
        super.init(rootView: PodHopperOnboardingRootView(onFinished: {
            finisher.onFinish?()
        }))

        finisher.onFinish = { [weak self] in
            self?.dismiss(animated: true)
        }
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Bridges the SwiftUI onboarding's finish callback to the hosting controller. The controller is
/// created after its root view, so the root view captures this holder and the controller fills in
/// the handler once it exists.
private final class PodHopperOnboardingFinisher {
    var onFinish: (() -> Void)?
}
