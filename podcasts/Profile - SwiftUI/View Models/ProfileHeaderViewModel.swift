import Foundation
import PocketCastsServer
import SwiftUI
import UIKit

/// View model for the header view that appears on the Profile tab view
class ProfileHeaderViewModel: ProfileDataViewModel {
    weak var navigationController: UINavigationController? = nil

    init(navigationController: UINavigationController? = nil) {
        super.init()

        self.navigationController = navigationController
    }

    /// Whether a PodHopper account is currently signed in.
    var isSignedIn: Bool {
        PodHopperSupabaseClient.shared.isLoggedIn()
    }

    /// The signed-in PodHopper account email, or an empty string when signed out.
    var accountEmail: String {
        PodHopperSupabaseClient.shared.signedInEmail ?? ""
    }

    /// Opens PodHopper's auth/account screen: the login flow when signed out, or the account view
    /// (email + logout) when signed in. Refreshes the header when the screen finishes so the account
    /// section reflects the new state.
    func accountTapped() {
        Analytics.track(.profileAccountButtonTapped)

        let authController = PodHopperAuthHostingController(onFinished: { [weak self] in
            self?.update()
        })
        navigationController?.present(authController, animated: true)
    }

    /// Signs out of the PodHopper account and refreshes the header.
    func logout() {
        PodHopperSupabaseClient.shared.logout()
        update()
    }

    /// Confirms before signing out, then signs out. The confirmation is presented through the
    /// navigation controller because the header is a SwiftUI view embedded as a table header view
    /// (via themedUIView), so it has no SwiftUI presentation context and a SwiftUI alert cannot show.
    func logoutTapped() {
        let alert = UIAlertController(
            title: nil,
            message: "Are you sure you want to logout of your PodHopper account?",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "No", style: .cancel))
        alert.addAction(UIAlertAction(title: "Yes", style: .destructive) { [weak self] _ in
            self?.logout()
        })

        let presenter = navigationController?.topViewController ?? navigationController
        presenter?.present(alert, animated: true)
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
