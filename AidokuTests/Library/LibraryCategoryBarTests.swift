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
    @Test func headerViewLayoutOverflowScrollAndDelegateBehavior() {
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

        #expect(header.pillButtons.count == 6)
        #expect(header.pillButtons[5].isSelected)
        #expect(header.pillButtons[5].accessibilityLabel == "Ongoing")

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
    @Test func libraryViewControllerUsesStackedTopHeaderWithoutSearchBar() async {
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
        #expect(vc.navigationItem.searchController == nil)
        vc.viewModel.categories = ["Action", "Comedy"]
        vc.viewModel.filterGroups = [FilterGroup(title: "Ongoing", filters: [])]
        vc.viewModel.currentCategory = "Action"
        vc.viewModel.filters = [LibraryFilter(type: .downloaded, value: nil, exclude: false)]
        vc.collectionView.collectionViewLayout = vc.makeCollectionViewLayout()
        vc.collectionView.reloadData()
        vc.collectionView.layoutIfNeeded()
        vc.view.layoutIfNeeded()

        let layoutConfig = (vc.collectionView.collectionViewLayout as? UICollectionViewCompositionalLayout)?.configuration
        #expect(layoutConfig?.boundarySupplementaryItems.count == 1)
        let topBoundary = layoutConfig?.boundarySupplementaryItems.first
        #expect(topBoundary?.elementKind == UICollectionView.elementKindSectionHeader)
        #expect(topBoundary?.layoutSize.heightDimension.dimension == 88)

        let topHeader = vc.collectionView
            .visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader)
            .first as? LibraryTopHeaderView
        #expect(topHeader != nil)
        if let topHeader {
            #expect(!topHeader.categoryBarView.isHidden)
            #expect(!topHeader.activeFiltersView.isHidden)
            let categoryFrame = topHeader.convert(topHeader.categoryBarView.bounds, from: topHeader.categoryBarView)
            let filtersFrame = topHeader.convert(topHeader.activeFiltersView.bounds, from: topHeader.activeFiltersView)
            #expect(abs(categoryFrame.height - 44) < 0.01)
            #expect(abs(filtersFrame.height - 38) < 0.01)
            #expect(abs(filtersFrame.minY - 44) < 0.01)
            #expect(filtersFrame.minY >= categoryFrame.maxY)
            #expect(!categoryFrame.intersects(filtersFrame))
            #expect(abs((topHeader.bounds.height - filtersFrame.maxY) - LibraryTopHeaderView.bottomPadding) < 0.01)
        }
        #expect(topHeader?.categoryBarView.currentSnapshot?.selectedIndexPath == IndexPath(row: 0, section: 1))

        vc.viewModel.categories = ["Action", "Comedy", "Drama"]
        AppSettings.library.lockLibrary.set(true)
        AppSettings.library.lockedCategories.set(["Drama"])
        vc.updateHeaderCategories()
        vc.updateHeaderLockIcons()

        #expect(topHeader?.categoryBarView.currentSnapshot?.totalItemCount == 5)
        #expect(topHeader?.categoryBarView.currentSnapshot?.allItems.first { $0.title == "Drama" }?.isLocked == true)

        vc.clearAllFilters()
        let clearedConfig = (vc.collectionView.collectionViewLayout as? UICollectionViewCompositionalLayout)?.configuration
        #expect(clearedConfig?.boundarySupplementaryItems.first?.layoutSize.heightDimension.dimension == 50)
        await vc.forkFilterSortCoordinator.activeReloadTask?.value

        vc.viewModel.categories = []
        vc.viewModel.filterGroups = []
        vc.toggleFilterFromSheet(method: .downloaded)
        let filtersOnlyConfig = (vc.collectionView.collectionViewLayout as? UICollectionViewCompositionalLayout)?.configuration
        #expect(filtersOnlyConfig?.boundarySupplementaryItems.count == 1)
        #expect(filtersOnlyConfig?.boundarySupplementaryItems.first?.layoutSize.heightDimension.dimension == 44)
        await vc.forkFilterSortCoordinator.activeReloadTask?.value

        vc.clearAllFilters()
        let neitherConfig = (vc.collectionView.collectionViewLayout as? UICollectionViewCompositionalLayout)?.configuration
        #expect(neitherConfig?.boundarySupplementaryItems.isEmpty ?? false)
        await vc.forkFilterSortCoordinator.activeReloadTask?.value
    }

    @MainActor
    @Test func topHeaderTotalHeightAndBottomPaddingAcrossAllModes() {
        #expect(LibraryTopHeaderView.totalHeight(showCategories: false, showActiveFilters: false) == 0)
        #expect(LibraryTopHeaderView.totalHeight(showCategories: true, showActiveFilters: false) == 50)
        #expect(LibraryTopHeaderView.totalHeight(showCategories: false, showActiveFilters: true) == 44)
        #expect(LibraryTopHeaderView.totalHeight(showCategories: true, showActiveFilters: true) == 88)

        let zeroHeader = LibraryTopHeaderView(frame: .zero)
        zeroHeader.configureVisibility(showCategories: true, showActiveFilters: true)
        zeroHeader.setNeedsLayout()
        zeroHeader.layoutIfNeeded()
        #expect(!zeroHeader.bounds.width.isNaN && !zeroHeader.bounds.height.isNaN)

        let categoriesOnlyHeader = LibraryTopHeaderView(frame: CGRect(x: 0, y: 0, width: 390, height: 50))
        categoriesOnlyHeader.configureVisibility(showCategories: true, showActiveFilters: false)
        categoriesOnlyHeader.setNeedsLayout()
        categoriesOnlyHeader.layoutIfNeeded()
        #expect(!categoriesOnlyHeader.categoryBarView.isHidden)
        #expect(categoriesOnlyHeader.activeFiltersView.isHidden)
        let catOnlyFrame = categoriesOnlyHeader.convert(
            categoriesOnlyHeader.categoryBarView.bounds,
            from: categoriesOnlyHeader.categoryBarView
        )
        #expect(abs(catOnlyFrame.minY) < 0.01)
        #expect(abs(catOnlyFrame.height - 44) < 0.01)
        #expect(abs((categoriesOnlyHeader.bounds.height - catOnlyFrame.maxY) - LibraryTopHeaderView.bottomPadding) < 0.01)

        let filtersOnlyHeader = LibraryTopHeaderView(frame: CGRect(x: 0, y: 0, width: 390, height: 44))
        filtersOnlyHeader.configureVisibility(showCategories: false, showActiveFilters: true)
        filtersOnlyHeader.setNeedsLayout()
        filtersOnlyHeader.layoutIfNeeded()
        #expect(filtersOnlyHeader.categoryBarView.isHidden)
        #expect(!filtersOnlyHeader.activeFiltersView.isHidden)
        let filtersOnlyFrame = filtersOnlyHeader.convert(
            filtersOnlyHeader.activeFiltersView.bounds,
            from: filtersOnlyHeader.activeFiltersView
        )
        #expect(abs(filtersOnlyFrame.minY) < 0.01)
        #expect(abs(filtersOnlyFrame.height - 38) < 0.01)
        #expect(abs((filtersOnlyHeader.bounds.height - filtersOnlyFrame.maxY) - LibraryTopHeaderView.bottomPadding) < 0.01)

        let bothHeader = LibraryTopHeaderView(frame: CGRect(x: 0, y: 0, width: 390, height: 88))
        bothHeader.configureVisibility(showCategories: true, showActiveFilters: true)
        bothHeader.setNeedsLayout()
        bothHeader.layoutIfNeeded()
        #expect(!bothHeader.categoryBarView.isHidden)
        #expect(!bothHeader.activeFiltersView.isHidden)
        let bothCategoryFrame = bothHeader.convert(
            bothHeader.categoryBarView.bounds,
            from: bothHeader.categoryBarView
        )
        let bothFiltersFrame = bothHeader.convert(
            bothHeader.activeFiltersView.bounds,
            from: bothHeader.activeFiltersView
        )
        #expect(abs(bothCategoryFrame.minY) < 0.01)
        #expect(abs(bothCategoryFrame.height - 44) < 0.01)
        #expect(abs(bothFiltersFrame.minY - 44) < 0.01)
        #expect(abs(bothFiltersFrame.height - 38) < 0.01)
        #expect(!bothCategoryFrame.intersects(bothFiltersFrame))
        #expect(abs((bothHeader.bounds.height - bothFiltersFrame.maxY) - LibraryTopHeaderView.bottomPadding) < 0.01)
    }
}
