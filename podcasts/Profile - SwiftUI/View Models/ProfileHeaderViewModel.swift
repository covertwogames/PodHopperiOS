import Foundation
import SwiftUI

/// View model for the header view that appears on the Profile tab view
class ProfileHeaderViewModel: ProfileDataViewModel {
    weak var navigationController: UINavigationController? = nil

    init(navigationController: UINavigationController? = nil) {
        super.init()

        self.navigationController = navigationController
    }

    /// Opens PodHopper's auth/account screen: the login flow when signed out, or the account view
    /// (email + logout) when signed in.
    func accountTapped() {
        Analytics.track(.profileAccountButtonTapped)

        let authController = PodHopperAuthHostingController()
        navigationController?.present(authController, animated: true)
    }

    func shareTapped() {
        guard let presenter = navigationController?.topViewController else { return }

        let shareView = ShareProfileView(
            onOpenPrivacySettings: { [weak self] in
                presenter.dismiss(animated: true) {
                    self?.navigationController?.pushViewController(PrivacySettingsViewController(), animated: true)
                }
            },
            onPresentShareActivity: { [weak presenter] items in
                guard let presented = presenter?.presentedViewController ?? presenter else { return }
                let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
                activityVC.popoverPresentationController?.sourceView = presented.view
                presented.present(activityVC, animated: true)
            }
        )

        let hostingController = PCHostingController(rootView: shareView)
        presenter.present(hostingController, animated: true)
    }
}
