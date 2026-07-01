import Foundation
import UIKit

/// Pull-to-refresh control that shows the standard iOS refresh spinner. PodHopper replaced the old
/// custom Pocket Casts logo animation with the system spinner, keeping the small API the refresh
/// controllers rely on (perform, set(text:), and theme-based tinting).
class CustomRefreshControl: UIRefreshControl {
    var perform: ((CustomRefreshControl) -> Void)?

    var style: ThemeStyle = .secondaryText02 {
        didSet { updateTintColor() }
    }

    var themeOverride: Theme.ThemeType? {
        didSet { updateTintColor() }
    }

    /// When set, overrides the theme-based tint color. Set to `nil` to fall back to the theme.
    var customTintColor: UIColor? {
        didSet { updateTintColor() }
    }

    private var currentText = L10n.refreshControlPullToRefresh

    override init() {
        super.init(frame: .zero)
        addTarget(self, action: #selector(didTriggerRefresh), for: .valueChanged)
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: Constants.Notifications.themeChanged, object: nil)
        updateTintColor()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func set(text: String) {
        currentText = text
        applyTitle()
    }

    private func tintColorForState() -> UIColor {
        customTintColor ?? AppTheme.colorForStyle(style, themeOverride: themeOverride)
    }

    private func updateTintColor() {
        tintColor = tintColorForState()
        applyTitle()
    }

    private func applyTitle() {
        attributedTitle = NSAttributedString(
            string: currentText,
            attributes: [
                .foregroundColor: tintColorForState(),
                .font: UIFont.systemFont(ofSize: 12, weight: .semibold)
            ]
        )
    }

    @objc private func themeDidChange() {
        updateTintColor()
    }

    @objc private func didTriggerRefresh() {
        perform?(self)
    }
}
