import PocketCastsDataModel
import PocketCastsUtils
import UIKit
import SwiftUI
import PocketCastsServer

extension PodcastListViewController: UICollectionViewDelegate, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private static let podcastSquareCellId = "PodcastGridCell"
    private static let podcastListCellId = "PodcastListCell"
    private static let folderSquareCellId = "FolderGridCell"
    private static let folderListCellId = "FolderListCell"
    private static let emptyStateCellId = "EmptyStateCell"

    func registerCells() {
        podcastsCollectionView.register(UINib(nibName: "PodcastGridCell", bundle: nil), forCellWithReuseIdentifier: PodcastListViewController.podcastSquareCellId)
        podcastsCollectionView.register(UINib(nibName: "PodcastListCell", bundle: nil), forCellWithReuseIdentifier: PodcastListViewController.podcastListCellId)
        podcastsCollectionView.register(UINib(nibName: "FolderGridCell", bundle: nil), forCellWithReuseIdentifier: PodcastListViewController.folderSquareCellId)
        podcastsCollectionView.register(UINib(nibName: "FolderListCell", bundle: nil), forCellWithReuseIdentifier: PodcastListViewController.folderListCellId)
        podcastsCollectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: PodcastListViewController.emptyStateCellId)

        // Register header view for banner ads
    }

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        1
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        itemCount()
    }

    private func makeEmptyStateView() -> EmptyStateView<Text, DefaultEmptyStateStyle> {
        EmptyStateView(
            title: L10n.podcastGridNoPodcastsTitle,
            message: L10n.podcastGridNoPodcastsMsg,
            icon: { Image("podcastlist_smallgrid").renderingMode(.template) },
            actions: [
                .init(title: L10n.podcastGridDiscoverPodcasts, action: {
                    Analytics.track(.podcastsListDiscoverButtonTapped)
                    NavigationManager.sharedManager.navigateTo(NavigationManager.discoverPageKey)
                })
            ],
            style: DefaultEmptyStateStyle.defaultStyle
        )
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let libraryType = Settings.libraryType()
        let item = itemAt(indexPath: indexPath)

        if item?.isEmpty == true {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PodcastListViewController.emptyStateCellId, for: indexPath)
            cell.contentConfiguration = UIHostingConfiguration {
                makeEmptyStateView()
            }
            .margins(.horizontal, 16)
            .margins(.vertical, 8)
            return cell
        }

        if libraryType == .list {
            if item?.podcast != nil {
                return collectionView.dequeueReusableCell(withReuseIdentifier: PodcastListViewController.podcastListCellId, for: indexPath)
            } else {
                return collectionView.dequeueReusableCell(withReuseIdentifier: PodcastListViewController.folderListCellId, for: indexPath)
            }
        }
        if item?.podcast != nil {
            return collectionView.dequeueReusableCell(withReuseIdentifier: PodcastListViewController.podcastSquareCellId, for: indexPath)
        } else {
            return collectionView.dequeueReusableCell(withReuseIdentifier: PodcastListViewController.folderSquareCellId, for: indexPath)
        }
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let item = itemAt(indexPath: indexPath) else { return }

        let libraryType = Settings.libraryType()
        let badgeType = Settings.podcastBadgeType()

        if libraryType == .list {
            if let podcast = item.podcast {
                let castCell = cell as! PodcastListCell
                castCell.populateFrom(podcast, badgeType: badgeType)
            } else if let folder = item.folder {
                let castCell = cell as! FolderListCell
                castCell.populateFrom(folder: folder, badgeType: badgeType)
            }
        } else {
            if let podcast = item.podcast {
                let castCell = cell as! PodcastGridCell
                castCell.populateFrom(podcast: podcast, badgeType: badgeType, libraryType: libraryType)
            } else if let folder = item.folder {
                let castCell = cell as! FolderGridCell
                castCell.populateFrom(folder: folder, badgeType: badgeType, libraryType: libraryType)
            }
        }

        // Sync reorder-edit treatment so reused/recycled cells stay correct. Idempotent
        // setters on the cell make in-state calls cheap, so we don't toggle off-then-on.
        if isEditingOrder, item.isEmpty == false {
            applyEditingTreatment(to: cell)
        } else {
            removeEditingTreatment(from: cell)
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)

        let selectedItem = itemAt(indexPath: indexPath)

        if selectedItem?.isEmpty == true {
            return
        }

        if let podcast = selectedItem?.podcast {
            Analytics.track(.podcastsListPodcastTapped)
            NavigationManager.sharedManager.navigateTo(NavigationManager.podcastPageKey, data: [NavigationManager.podcastKey: podcast])
        } else if let folder = selectedItem?.folder {
            Analytics.track(.podcastsListFolderTapped)
            NavigationManager.sharedManager.navigateTo(NavigationManager.folderPageKey, data: [NavigationManager.folderKey: folder])
        }
    }

    // MARK: - Re-ordering

    func saveSortOrder() {
        for (index, listItem) in gridItems.enumerated() {
            if let podcast = listItem.podcast {
                podcast.sortOrder = Int32(index)
            } else if let folder = listItem.folder {
                folder.sortOrder = Int32(index)
            }
        }

        let allPodcasts = gridItems.compactMap(\.podcast)
        let allFolders = gridItems.compactMap(\.folder)

        DataManager.sharedManager.saveSortOrders(podcasts: allPodcasts)
        DataManager.sharedManager.saveSortOrders(folders: allFolders, syncModified: TimeFormatter.currentUTCTimeInMillis())
        Settings.setHomeFolderSortOrder(order: .custom)
    }

    // MARK: - Row Sizing

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let item = itemAt(indexPath: indexPath)
        if item?.isEmpty == true {
            let sizingView = makeEmptyStateView()
                .environmentObject(Theme.sharedTheme)

            let hostingController = UIHostingController(rootView: sizingView)
            let targetSize = CGSize(width: collectionView.bounds.width - 32, height: UIView.layoutFittingCompressedSize.height)
            let size = hostingController.sizeThatFits(in: targetSize)

            return CGSize(width: collectionView.bounds.width, height: size.height)
        }
        return gridHelper.collectionView(collectionView, sizeForItemAt: indexPath, itemCount: itemCount())
    }

    func updateFlowLayoutSize() {
        if let flowLayout = podcastsCollectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            flowLayout.invalidateLayout() // force the elements to get laid out again with the new size
        }
    }

}
