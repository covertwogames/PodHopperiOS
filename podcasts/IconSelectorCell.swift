import PocketCastsServer
import UIKit

protocol IconSelectorCellDelegate: AnyObject {
    func changeIcon(icon: IconType)
    func iconSelectorPresentingVC() -> UIViewController
}

enum IconType: Int, CaseIterable, AnalyticsDescribable {
    case primary, dark, roundLight, roundDark, indigo
    case rose, pocketCats

    /// Finds the IconType for the given iconName or .primary if there isn't a match
    init(iconName: String) {
        self = Self.availableIcons.first(where: { $0.iconName == iconName }) ?? .primary
    }

    static var availableIcons: [IconType] {
        // PodHopper: the seven PodHopper icons, all free (no Plus lock). The selector indexes
        // them by raw value (0-6), so keep these in the same order as the cases above.
        [.primary, .dark, .roundLight, .roundDark, .indigo, .rose, .pocketCats]
    }

    var description: String {
        switch self {
        case .primary:
            return "Green"
        case .dark:
            return "Midnight"
        case .roundLight:
            return "Light"
        case .roundDark:
            return "Ink"
        case .indigo:
            return "Slate"
        case .rose:
            return "Cosmic"
        case .pocketCats:
            return "Cosmic Noir"
        }
    }

    var previewIconName: String {
        switch self {
        case .primary:
            return "AppIcon-Default"
        case .dark:
            return "AppIcon-Dark"
        case .roundLight:
            return "AppIcon-Round"
        case .roundDark:
            return "AppIcon-Round-Dark"
        case .indigo:
            return "AppIcon-Indigo"
        case .rose:
            return "AppIcon-Round-Pink"
        case .pocketCats:
            return "AppIcon-Pocket-Cats"
        }
    }

    var iconName: String? {
        switch self {
        case .primary:
            return "AppIcon-Default"
        case .dark:
            return "AppIcon-Dark"
        case .roundLight:
            return "AppIcon-Round"
        case .roundDark:
            return "AppIcon-Round-Dark"
        case .indigo:
            return "AppIcon-Indigo"
        case .rose:
            return "AppIcon-Round-Pink"
        case .pocketCats:
            return "AppIcon-Pocket-Cats"
        }
    }

    var analyticsDescription: String {
        switch self {
        case .primary:
            return "default"
        case .dark:
            return "dark"
        case .roundLight:
            return "round_light"
        case .roundDark:
            return "round_dark"
        case .indigo:
            return "indigo"
        case .rose:
            return "rose"
        case .pocketCats:
            return "pocket_cats"
        }
    }

    /// Whether the icon is unlocked for the users active subscription
    var isUnlocked: Bool {
        SubscriptionHelper.activeTier >= subscription
    }

    /// The minimum subscription level required to unlock the icon. PodHopper: every icon is free.
    var subscription: SubscriptionTier {
        .none
    }
}

class IconSelectorCell: ThemeableCell, UICollectionViewDataSource, UICollectionViewDelegate, GridLayoutDelegate {
    @IBOutlet var collectionView: ThemeableAccessibilityCollectionView! {
        didSet {
            collectionView.register(UINib(nibName: "ThemeAbstractCell", bundle: nil), forCellWithReuseIdentifier: themeAbstractCellId)
            collectionView.style = .primaryUi02
            collectionView.allowsMultipleSelection = false
            collectionView.contentInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        }
    }

    override func awakeFromNib() {
        super.awakeFromNib()

        selectedIcon = IconType(iconName: UIApplication.shared.alternateIconName ?? "AppIcon-Default")

        if let gridLayout = collectionView.collectionViewLayout as? GridLayout {
            gridLayout.delegate = self
            gridLayout.numberOfRowsOrColumns = 1
            gridLayout.scrollDirection = .horizontal
            gridLayout.itemSpacing = itemSpacing
        }
    }

    private var numVisibleColoumns = 3 as CGFloat
    private var itemSpacing = 0 as CGFloat
    private var maxCellWidth = 124 as CGFloat
    var cellHeight: CGFloat {
        cellWidth * 148 / 124
    } // Design: width = 124 height = 148
    var peekWidth = 30 as CGFloat
    var cellWidth: CGFloat {
        let widthAvailable = UIScreen.main.bounds.width // view.bounds.width
        let maxWidth = maxCellWidth > 0 ? maxCellWidth : widthAvailable
        let calculatedWidth = min(maxWidth, (widthAvailable - peekWidth - (itemSpacing * (numVisibleColoumns + 1))) / numVisibleColoumns)
        return calculatedWidth
    }

    weak var delegate: IconSelectorCellDelegate?

    private let themeAbstractCellId = "ThemeAbstractCell"

    var selectedIcon: IconType = .primary

    // MARK: - GridLayoutDelegate

    func sizeForItem(inCollectionView collectionView: UICollectionView, withLayout layout: UICollectionViewLayout, atIndexPath indexPath: IndexPath) -> CGSize {
        CGSize(width: cellWidth, height: cellHeight)
    }

    // MARK: - UICollectionView Methods

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        1
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        IconType.availableIcons.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: themeAbstractCellId, for: indexPath) as! ThemeAbstractCell

        cell.imageView.layer.cornerRadius = 18.95
        cell.shadowView.layer.cornerRadius = 18.95
        cell.underShadowView.layer.cornerRadius = 18.95
        cell.selectionView.layer.cornerRadius = 26

        let iconType = IconType(rawValue: indexPath.row) ?? .primary
        cell.nameLabel.text = iconType.description
        cell.imageView.image = UIImage(named: iconType.previewIconName)
        cell.isLocked = !iconType.isUnlocked

        cell.isCellSelected = selectedIcon == iconType

        cell.isAccessibilityElement = true
        cell.accessibilityLabel = cell.nameLabel.text

        if cell.isLocked {
            switch iconType.subscription {
            case .patron:
                cell.accessibilityHint = L10n.accessibilityPatronOnly
                cell.lockImage = UIImage(named: "patron-locked")
            default:
                cell.accessibilityHint = L10n.accessibilityPlusOnly
                cell.lockImage = UIImage(named: "plusGoldCircle")
            }
        }

        return cell
    }

    // MARK: - CollectionView Delegate

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let icon = IconType(rawValue: indexPath.item), icon.isUnlocked else {
            collectionView.deselectItem(at: indexPath, animated: true)

            if let delegate {
                let context: OnboardingFlow.Context? = IconType(rawValue: indexPath.item).flatMap {
                    ["product": ProductInfo(plan: $0.subscription == .patron ? .patron : .plus, frequency: .yearly)]
                }

                NavigationManager.sharedManager.showUpsellView(from: delegate.iconSelectorPresentingVC(), source: .icons, context: context)
            }
            return
        }

        selectedIcon = icon
        delegate?.changeIcon(icon: icon)
        collectionView.reloadData()
    }

    func scrollToSelected() {
        collectionView.scrollToItem(at: IndexPath(item: selectedIcon.rawValue, section: 0), at: .centeredHorizontally, animated: false)
    }
}
