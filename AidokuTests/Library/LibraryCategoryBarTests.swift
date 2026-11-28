//
//  LibraryCategoryBarTests.swift
//  AidokuTests
//
//  Created by Dokuha on 11/28/26.
//

@testable import Aidoku
import Testing
import UIKit

@Suite(.serialized) struct LibraryCategoryBarTests {
    private static let persistedKeys = [
        "Library.showUncategorizedCategory",
        "Library.lockLibrary",
        "Library.lockedCategories",
        "Library.currentCategory",
        "Library.filters"
    ]

    private func snapshotUserDefaults() -> [String: Any?] {
        let defaults = UserDefaults.standard
        var snapshot: [String: Any?] = [:]
        for key in Self.persistedKeys {
            snapshot[key] = defaults.object(forKey: key)
        }
        return snapshot
    }

    private func restoreUserDefaults(_ snapshot: [String: Any?]) {
        let defaults = UserDefaults.standard
        for key in Self.persistedKeys {
            if let value = snapshot[key] ?? nil {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    @MainActor
    private final class SpyCategoryDelegate: LibraryCategorySelectionHeaderDelegate {
        var selectedPaths: [IndexPath] = []

        func optionSelected(_ indexPath: IndexPath) {
            selectedPaths.append(indexPath)
        }
    }

    @Test func builderMapsSectionsIndexPathsAndUncategorizedOption() {
        let snapshotWithCategories = LibraryCategoryBarBuilder.build(
            LibraryCategoryBarInput(
                showUncategorized: false,
                categories: ["Action", "Romance"],
                filterGroupTitles: ["Ongoing", "Favorites"],
                currentCategory: nil,
                lockLibraryEnabled: false,
                lockedCategories: []
            )
        )

        #expect(snapshotWithCategories.sections.count == 3)
        #expect(snapshotWithCategories.sections[0].items.map(\.indexPath) == [IndexPath(row: 0, section: 0)])
        #expect(
            snapshotWithCategories.sections[1].items.map(\.indexPath) == [
                IndexPath(row: 0, section: 1),
                IndexPath(row: 1, section: 1)
            ]
        )
        #expect(
            snapshotWithCategories.sections[2].items.map(\.indexPath) == [
                IndexPath(row: 0, section: 2),
                IndexPath(row: 1, section: 2)
            ]
        )
        #expect(snapshotWithCategories.selectedIndexPath == IndexPath(row: 0, section: 0))

        let snapshotFilterGroupsOnly = LibraryCategoryBarBuilder.build(
            LibraryCategoryBarInput(
                showUncategorized: true,
                categories: [],
                filterGroupTitles: ["Ongoing"],
                currentCategory: "Ongoing",
                lockLibraryEnabled: false,
                lockedCategories: []
            )
        )

        #expect(snapshotFilterGroupsOnly.sections.count == 2)
        #expect(
            snapshotFilterGroupsOnly.sections[0].items.map(\.indexPath) == [
                IndexPath(row: 0, section: 0),
                IndexPath(row: 1, section: 0)
            ]
        )
        #expect(snapshotFilterGroupsOnly.sections[1].items.map(\.indexPath) == [IndexPath(row: 0, section: 1)])
        #expect(snapshotFilterGroupsOnly.selectedIndexPath == IndexPath(row: 0, section: 1))
    }

    @Test func builderResolvesSelectionsLockFlagsHiddenCategoriesAndQuickJumpThreshold() {
        let uncategorizedSelected = LibraryCategoryBarBuilder.build(
            LibraryCategoryBarInput(
                showUncategorized: true,
                categories: ["Action"],
                filterGroupTitles: [],
                currentCategory: "",
                lockLibraryEnabled: false,
                lockedCategories: []
            )
        )
        #expect(uncategorizedSelected.selectedIndexPath == IndexPath(row: 1, section: 0))

        let uncategorizedDisabled = LibraryCategoryBarBuilder.build(
            LibraryCategoryBarInput(
                showUncategorized: false,
                categories: ["Action"],
                filterGroupTitles: [],
                currentCategory: "",
                lockLibraryEnabled: false,
                lockedCategories: []
            )
        )
        #expect(uncategorizedDisabled.selectedIndexPath == IndexPath(row: 0, section: 0))

        let staleSelection = LibraryCategoryBarBuilder.build(
            LibraryCategoryBarInput(
                showUncategorized: false,
                categories: ["Action"],
                filterGroupTitles: [],
                currentCategory: "Deleted",
                lockLibraryEnabled: false,
                lockedCategories: []
            )
        )
        #expect(staleSelection.selectedIndexPath == IndexPath(row: 0, section: 0))

        let lockedSnapshot = LibraryCategoryBarBuilder.build(
            LibraryCategoryBarInput(
                showUncategorized: true,
                categories: ["Action", "Secret"],
                filterGroupTitles: ["Private Group"],
                currentCategory: "Secret",
                lockLibraryEnabled: true,
                lockedCategories: ["Secret", "Private Group"],
                hiddenCategories: []
            )
        )
        #expect(lockedSnapshot.allItems.first { $0.kind == .all }?.isLocked == true)
        #expect(lockedSnapshot.allItems.first { $0.kind == .uncategorized }?.isLocked == false)
        #expect(lockedSnapshot.allItems.first { $0.title == "Action" }?.isLocked == false)
        #expect(lockedSnapshot.allItems.first { $0.title == "Secret" }?.isLocked == true)
        #expect(lockedSnapshot.allItems.first { $0.title == "Private Group" }?.isLocked == true)

        let hiddenSnapshot = LibraryCategoryBarBuilder.build(
            LibraryCategoryBarInput(
                showUncategorized: false,
                categories: ["Secret", "Visible"],
                filterGroupTitles: ["FG"],
                currentCategory: "Secret",
                lockLibraryEnabled: false,
                lockedCategories: [],
                hiddenCategories: ["Secret"]
            )
        )
        let visibleItem = hiddenSnapshot.allItems.first { $0.title == "Visible" }
        let filterGroupItem = hiddenSnapshot.allItems.first { $0.title == "FG" }
        #expect(!hiddenSnapshot.allItems.contains { $0.title == "Secret" })
        #expect(visibleItem?.indexPath == IndexPath(row: 1, section: 1))
        #expect(filterGroupItem?.indexPath == IndexPath(row: 0, section: 2))
        #expect(hiddenSnapshot.selectedIndexPath == IndexPath(row: 0, section: 0))

        let fourItems = LibraryCategoryBarBuilder.build(
            LibraryCategoryBarInput(
                showUncategorized: false,
                categories: ["A", "B", "C"],
                filterGroupTitles: [],
                currentCategory: nil,
                lockLibraryEnabled: false,
                lockedCategories: []
            )
        )
        #expect(fourItems.totalItemCount == 4)
        #expect(!fourItems.shouldShowQuickJumpButton)

        let fiveItems = LibraryCategoryBarBuilder.build(
            LibraryCategoryBarInput(
                showUncategorized: true,
                categories: ["A", "B", "C"],
                filterGroupTitles: [],
                currentCategory: nil,
                lockLibraryEnabled: false,
                lockedCategories: []
            )
        )
        #expect(fiveItems.totalItemCount == 5)
        #expect(fiveItems.shouldShowQuickJumpButton)

        let lockedFilterGroupOnly = LibraryCategoryBarBuilder.build(
            LibraryCategoryBarInput(
                showUncategorized: false,
                categories: [],
                filterGroupTitles: ["Private Group"],
                currentCategory: "Private Group",
                lockLibraryEnabled: true,
                lockedCategories: ["Private Group"]
            )
        )
        let privateGroupItem = lockedFilterGroupOnly.allItems.first { $0.title == "Private Group" }
        #expect(privateGroupItem?.indexPath == IndexPath(row: 0, section: 1))
        #expect(privateGroupItem?.isLocked == true)
    }

    @MainActor
    @Test func headerViewLayoutQuickJumpMenuAndDelegateBehavior() {
        let header = LibraryCategoryBarHeaderView(frame: CGRect(x: 0, y: 0, width: 390, height: 44))
        let spy = SpyCategoryDelegate()
        header.delegate = spy

        let smallSnapshot = LibraryCategoryBarBuilder.build(
            LibraryCategoryBarInput(
                showUncategorized: false,
                categories: ["Action", "Comedy", "Drama"],
                filterGroupTitles: [],
                currentCategory: nil,
                lockLibraryEnabled: false,
                lockedCategories: []
            )
        )
        header.configure(with: smallSnapshot)
        header.layoutIfNeeded()

        #expect(header.pillButtons.count == 4)
        #expect(header.isQuickJumpButtonHidden)
        #expect(spy.selectedPaths.isEmpty)

        let firstPill = header.pillButtons[0]
        let firstFrame = header.convert(firstPill.bounds, from: firstPill)
        #expect(abs(firstFrame.minX - 16) < 0.01)
        #expect(firstPill.isSelected)
        #expect(firstPill.accessibilityTraits.contains(.selected))
        #expect(!header.pillButtons[1].isSelected)

        firstPill.sendActions(for: .primaryActionTriggered)
        #expect(spy.selectedPaths.isEmpty)

        header.pillButtons[1].sendActions(for: .primaryActionTriggered)
        #expect(spy.selectedPaths == [IndexPath(row: 0, section: 1)])

        let largeSnapshot = LibraryCategoryBarBuilder.build(
            LibraryCategoryBarInput(
                showUncategorized: true,
                categories: ["Action", "Comedy", "Drama"],
                filterGroupTitles: ["Ongoing"],
                currentCategory: "Ongoing",
                lockLibraryEnabled: false,
                lockedCategories: []
            )
        )
        header.configure(with: largeSnapshot)
        header.layoutIfNeeded()

        #expect(!header.isQuickJumpButtonHidden)
        #expect(header.quickJumpMenu?.children.count == 3)
        #expect(header.pillButtons.count == 6)
        #expect(header.pillButtons[5].isSelected)
        #expect(header.pillButtons[5].accessibilityLabel == "Ongoing")

        let menuActions = (header.quickJumpMenu?.children.compactMap { $0 as? UIMenu } ?? [])
            .flatMap { $0.children.compactMap { $0 as? UIAction } }
        #expect(menuActions.first { $0.title == "Ongoing" }?.state == .on)
        #expect(menuActions.first { $0.title == "Action" }?.state == .off)

        let longCategories = (1...10).map { "Category \($0) Collection" }
        let overflowSnapshot = LibraryCategoryBarBuilder.build(
            LibraryCategoryBarInput(
                showUncategorized: false,
                categories: longCategories,
                filterGroupTitles: [],
                currentCategory: longCategories.last,
                lockLibraryEnabled: false,
                lockedCategories: []
            )
        )
        header.configure(with: overflowSnapshot)
        header.layoutIfNeeded()
        #expect(header.currentScrollOffsetX > 0)
    }

    @MainActor
    @Test func libraryViewControllerUsesCategoryBarHeaderAndDualBoundaryLayout() async {
        let snapshot = snapshotUserDefaults()
        defer { restoreUserDefaults(snapshot) }

        AppSettings.library.showUncategorizedCategory.set(false)
        AppSettings.library.lockLibrary.set(false)
        AppSettings.library.lockedCategories.set([])

        let vc = LibraryViewController()
        let nav = UINavigationController(rootViewController: vc)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = nav
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        vc.loadViewIfNeeded()
        vc.viewModel.categories = ["Action", "Comedy"]
        vc.viewModel.filterGroups = [FilterGroup(title: "Ongoing", filters: [])]
        vc.viewModel.currentCategory = "Action"
        vc.viewModel.filters = [LibraryFilter(type: .downloaded, value: nil, exclude: false)]
        vc.collectionView.collectionViewLayout = vc.makeCollectionViewLayout()
        vc.collectionView.reloadData()
        vc.collectionView.layoutIfNeeded()
        vc.view.layoutIfNeeded()

        let layoutConfig = (vc.collectionView.collectionViewLayout as? UICollectionViewCompositionalLayout)?.configuration
        let categoryBoundary = layoutConfig?.boundarySupplementaryItems.first {
            $0.elementKind == UICollectionView.elementKindSectionHeader
        }
        let filtersBoundary = layoutConfig?.boundarySupplementaryItems.first {
            $0.elementKind == LibraryActiveFiltersHeaderView.elementKind
        }
        #expect(categoryBoundary?.layoutSize.heightDimension.dimension == 44)
        #expect(filtersBoundary?.layoutSize.heightDimension.dimension == 38)

        let header = vc.collectionView
            .visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader)
            .first as? LibraryCategoryBarHeaderView
        #expect(header != nil)
        #expect(header?.currentSnapshot?.selectedIndexPath == IndexPath(row: 0, section: 1))

        vc.viewModel.categories = ["Action", "Comedy", "Drama"]
        AppSettings.library.lockLibrary.set(true)
        AppSettings.library.lockedCategories.set(["Drama"])
        vc.updateHeaderCategories()
        vc.updateHeaderLockIcons()

        #expect(header?.currentSnapshot?.totalItemCount == 5)
        #expect(header?.isQuickJumpButtonHidden == false)
        #expect(header?.currentSnapshot?.allItems.first { $0.title == "Drama" }?.isLocked == true)

        vc.clearAllFilters()
        await vc.forkFilterSortCoordinator.activeReloadTask?.value
    }
}
