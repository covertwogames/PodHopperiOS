import SwiftUI
import UIKit

/// Presents PodHopper's Help & Feedback screen. Shown from the Profile tab in place of the old
/// Pocket Casts online support page. Wrapped in a navigation controller by the caller, so it sets a
/// title and a close button on its navigation item.
class PodHopperHelpHostingController: ThemedHostingController<PodHopperHelpView> {
    init() {
        super.init(rootView: PodHopperHelpView())
        title = L10n.settingsHelp
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(closeTapped))
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }
}
