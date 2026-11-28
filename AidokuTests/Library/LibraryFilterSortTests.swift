//
//  LibraryFilterSortTests.swift
//  AidokuTests
//
//  Created by Dokuha on 11/27/26.
//

@testable import Aidoku
import Testing
import UIKit

@Suite(.serialized) struct LibraryFilterSortTests {
    private static let persistedKeys = [
        "Library.filters",
        "Library.sortOption",
        "Library.sortAscending",
        "Library.lockLibrary",
        "Library.lockedCategories",
        "Library.currentCategory"
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

    @Test func triStateTogglingCyclesOffIncludeExcludeOff() {
        var filters: [LibraryFilter] = []
        #expect(LibraryFilterSortHelpers.state(for: .downloaded, in: filters) == .off)

        filters = LibraryFilterSortHelpers.toggling(method: .downloaded, in: filters)
        #expect(LibraryFilterSortHelpers.state(for: .downloaded, in: filters) == .included)
        #expect(filters == [LibraryFilter(type: .downloaded, value: nil, exclude: false)])

        filters = LibraryFilterSortHelpers.toggling(method: .downloaded, in: filters)
        #expect(LibraryFilterSortHelpers.state(for: .downloaded, in: filters) == .excluded)
        #expect(filters == [LibraryFilter(type: .downloaded, value: nil, exclude: true)])

        filters = LibraryFilterSortHelpers.toggling(method: .downloaded, in: filters)
        #expect(LibraryFilterSortHelpers.state(for: .downloaded, in: filters) == .off)
        #expect(filters.isEmpty)
    }

    @Test func valuedFiltersToggleAndRemoveIndependently() {
        var filters: [LibraryFilter] = []
        filters = LibraryFilterSortHelpers.toggling(
            method: .contentRating,
            value: MangaContentRating.nsfw.stringValue,
            in: filters
        )
        filters = LibraryFilterSortHelpers.toggling(
            method: .source,
            value: "mangadex",
            in: filters
        )
        filters = LibraryFilterSortHelpers.toggling(
            method: .source,
            value: "mangadex",
            in: filters
        )

        #expect(
            LibraryFilterSortHelpers.state(
                for: .contentRating,
                value: MangaContentRating.nsfw.stringValue,
                in: filters
            ) == .included
        )
        #expect(LibraryFilterSortHelpers.state(for: .source, value: "mangadex", in: filters) == .excluded)
        #expect(LibraryFilterSortHelpers.state(for: .source, value: "other", in: filters) == .off)

        let afterRemoval = LibraryFilterSortHelpers.removing(
            method: .source,
            value: "mangadex",
            from: filters
        )
        #expect(afterRemoval == [LibraryFilter(type: .contentRating, value: "nsfw", exclude: false)])
    }

    @Test func nextSortSelectsDefaultDirectionAndTogglesActiveDirection() {
        let initial = LibraryFilterSortHelpers.nextSort(
            currentMethod: .lastOpened,
            currentAscending: false,
            tappedMethod: .alphabetical
        )
        #expect(initial.method == .alphabetical)
        #expect(!initial.ascending)
        #expect(LibraryFilterSortHelpers.isVisuallyAscending(method: .alphabetical, sortAscending: false))

        let reversed = LibraryFilterSortHelpers.nextSort(
            currentMethod: initial.method,
            currentAscending: initial.ascending,
            tappedMethod: .alphabetical
        )
        #expect(reversed.method == .alphabetical)
        #expect(reversed.ascending)
        #expect(!LibraryFilterSortHelpers.isVisuallyAscending(method: .alphabetical, sortAscending: true))

        let nonAlpha = LibraryFilterSortHelpers.nextSort(
            currentMethod: .lastUpdated,
            currentAscending: true,
            tappedMethod: .lastUpdated
        )
        #expect(nonAlpha.method == .lastUpdated)
        #expect(!nonAlpha.ascending)
        #expect(!LibraryFilterSortHelpers.isVisuallyAscending(method: .lastUpdated, sortAscending: false))
    }

    @Test func activeFilterChipsAndMergedOptionsHandleIncludedExcludedAndStaleValues() {
        let filters = [
            LibraryFilter(type: .hasUnread, value: nil, exclude: false),
            LibraryFilter(type: .contentRating, value: "suggestive", exclude: true),
            LibraryFilter(type: .source, value: "removed-source", exclude: false),
            LibraryFilter(type: .category, value: "Action", exclude: false)
        ]

        let chips = LibraryFilterSortHelpers.activeFilterChips(for: filters) { key in
            key == "mangadex" ? "MangaDex" : key
        }
        #expect(chips.count == 4)
        #expect(!chips[0].isExcluded)
        #expect(chips[0].title == LibraryFilter.FilterMethod.hasUnread.title)
        #expect(chips[1].isExcluded)
        #expect(chips[1].title == String(format: NSLocalizedString("NOT_%@"), MangaContentRating.suggestive.title))
        #expect(chips[2].title == "removed-source")
        #expect(chips[3].title == "Action")

        let mergedSources = LibraryFilterSortHelpers.mergedFilterOptions(
            available: ["mangadex"],
            activeFilters: filters,
            method: .source
        )
        #expect(mergedSources == ["mangadex", "removed-source"])
    }

    @MainActor
    @Test func viewModelMutationsAndStateTrackFilterGroupsAndNoOps() {
        let snapshot = snapshotUserDefaults()
        defer { restoreUserDefaults(snapshot) }

        let viewModel = LibraryViewModel()
        viewModel.filters = []
        viewModel.clearAllFiltersMutation()
        #expect(viewModel.filters.isEmpty)

        let originalMethod = viewModel.sortMethod
        let originalAscending = viewModel.sortAscending
        #expect(!viewModel.applySortMutation(method: originalMethod, ascending: originalAscending))

        let targetMethod: LibraryViewModel.SortMethod = originalMethod == .alphabetical ? .lastOpened : .alphabetical
        #expect(viewModel.applySortMutation(method: targetMethod, ascending: !originalAscending))
        #expect(viewModel.sortMethod == targetMethod)
        #expect(viewModel.sortAscending == !originalAscending)

        viewModel.filterGroups = [FilterGroup(title: "Ongoing Picks", filters: [])]
        viewModel.currentCategory = "Action"
        let state = LibraryFilterSortState(viewModel: viewModel)
        #expect(!state.isViewingFilterGroup)
        #expect(state.activeFilterGroupTitle == nil)

        viewModel.currentCategory = "Ongoing Picks"
        state.update(from: viewModel)
        #expect(state.isViewingFilterGroup)
        #expect(state.activeFilterGroupTitle == "Ongoing Picks")
    }

    @MainActor
    @Test func activeFiltersHeaderViewHasLeadingMarginAndAccessibilityLabel() {
        let header = LibraryActiveFiltersHeaderView(frame: CGRect(x: 0, y: 0, width: 390, height: 38))
        let chips = LibraryFilterSortHelpers.activeFilterChips(
            for: [
                LibraryFilter(type: .hasUnread, value: nil, exclude: false),
                LibraryFilter(type: .downloaded, value: nil, exclude: true)
            ],
            resolveSourceName: { $0 }
        )

        header.configure(chips: chips, onRemoveFilter: { _ in }, onClearAll: {})
        header.layoutIfNeeded()

        #expect(header.displayedChips.count == 2)
        #expect(header.arrangedChipViews.count == 3)

        let firstChip = header.arrangedChipViews[0]
        let secondChip = header.arrangedChipViews[1]
        let firstFrame = header.convert(firstChip.bounds, from: firstChip)
        #expect(firstFrame.minX == 16)
        #expect(firstChip.accessibilityLabel == ForkL10n.format("LIBRARY_REMOVE_FILTER_CHIP_A11Y_FORMAT", chips[0].title))
        #expect(secondChip.accessibilityLabel == ForkL10n.format("LIBRARY_REMOVE_FILTER_CHIP_A11Y_FORMAT", chips[1].title))
    }

    @MainActor
    @Test func libraryViewControllerUpdatesVisibleChipsAndSerializesCoalescedReloads() async {
        let snapshot = snapshotUserDefaults()
        defer { restoreUserDefaults(snapshot) }

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
        vc.viewModel.categories = ["Action"]
        vc.viewModel.filters = []
        vc.syncFilterSortUIState()
        #expect(!vc.forkFilterSortCoordinator.isShowingActiveFiltersHeader)

        vc.toggleFilterFromSheet(method: .downloaded)
        #expect(vc.viewModel.filters == [LibraryFilter(type: .downloaded, value: nil, exclude: false)])
        #expect(vc.forkFilterSortCoordinator.isShowingActiveFiltersHeader)

        vc.collectionView.layoutIfNeeded()
        vc.view.layoutIfNeeded()

        let layoutConfig = (vc.collectionView.collectionViewLayout as? UICollectionViewCompositionalLayout)?.configuration
        #expect(layoutConfig?.boundarySupplementaryItems.count == 1)
        let topBoundary = layoutConfig?.boundarySupplementaryItems.first
        #expect(topBoundary?.elementKind == UICollectionView.elementKindSectionHeader)
        #expect(topBoundary?.layoutSize.heightDimension.dimension == 88)

        let initialHeader = vc.collectionView
            .visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader)
            .first as? LibraryTopHeaderView
        #expect(initialHeader != nil)
        if let initialHeader {
            let categoryFrame = initialHeader.convert(
                initialHeader.categoryBarView.bounds,
                from: initialHeader.categoryBarView
            )
            let filtersFrame = initialHeader.convert(
                initialHeader.activeFiltersView.bounds,
                from: initialHeader.activeFiltersView
            )
            #expect(abs(categoryFrame.height - 44) < 0.01)
            #expect(abs(filtersFrame.height - 38) < 0.01)
            #expect(abs(filtersFrame.minY - 44) < 0.01)
            #expect(abs(filtersFrame.maxY - 82) < 0.01)
            #expect(filtersFrame.minY >= categoryFrame.maxY)
            #expect(!categoryFrame.intersects(filtersFrame))
            #expect(abs((initialHeader.bounds.height - filtersFrame.maxY) - LibraryTopHeaderView.bottomPadding) < 0.01)
        }
        #expect(initialHeader?.activeFiltersView.displayedChips.count == 1)

        let genAfterFirst = vc.forkFilterSortCoordinator.reloadGeneration
        #expect(vc.forkFilterSortCoordinator.activeReloadTask != nil)

        vc.toggleFilterFromSheet(method: .hasUnread)
        #expect(vc.forkFilterSortCoordinator.reloadGeneration == genAfterFirst &+ 1)
        #expect(vc.forkFilterSortCoordinator.pendingLibraryLoad)

        let toggledSortMethod: LibraryViewModel.SortMethod = vc.viewModel.sortMethod == .alphabetical
            ? .lastUpdated
            : .alphabetical
        vc.selectSortFromSheet(method: toggledSortMethod)
        #expect(vc.forkFilterSortCoordinator.pendingLibraryLoad)
        #expect(vc.forkFilterSortCoordinator.pendingSortOnly)

        let updatedHeader = vc.collectionView
            .visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader)
            .first as? LibraryTopHeaderView
        #expect(updatedHeader?.activeFiltersView.displayedChips.count == 2)
        #expect(updatedHeader?.activeFiltersView.arrangedChipViews.count == 3)

        await vc.forkFilterSortCoordinator.activeReloadTask?.value
        #expect(vc.forkFilterSortCoordinator.activeReloadTask == nil)
        #expect(!vc.forkFilterSortCoordinator.pendingLibraryLoad)
        #expect(!vc.forkFilterSortCoordinator.pendingSortOnly)

        vc.viewModel.categories = ["Action"]
        vc.clearAllFilters()
        #expect(vc.viewModel.filters.isEmpty)
        #expect(!vc.forkFilterSortCoordinator.isShowingActiveFiltersHeader)
        let clearedConfig = (vc.collectionView.collectionViewLayout as? UICollectionViewCompositionalLayout)?.configuration
        #expect(clearedConfig?.boundarySupplementaryItems.first?.layoutSize.heightDimension.dimension == 50)
        await vc.forkFilterSortCoordinator.activeReloadTask?.value
    }

    @MainActor
    @Test func lockTransitionsUpdateTopHeaderLayoutHeightWithoutOverlap() {
        let snapshot = snapshotUserDefaults()
        defer { restoreUserDefaults(snapshot) }

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
        vc.viewModel.categories = ["Action"]
        vc.viewModel.filters = [LibraryFilter(type: .downloaded, value: nil, exclude: false)]
        vc.viewModel.currentCategory = nil
        vc.locked = false
        vc.syncFilterSortUIState()
        vc.collectionView.reloadData()
        vc.collectionView.layoutIfNeeded()
        vc.view.layoutIfNeeded()

        let unlockedConfig = (vc.collectionView.collectionViewLayout as? UICollectionViewCompositionalLayout)?.configuration
        #expect(unlockedConfig?.boundarySupplementaryItems.first?.layoutSize.heightDimension.dimension == 88)
        #expect(vc.forkFilterSortCoordinator.lastTopHeaderHeight == 88)

        let unlockedHeader = vc.collectionView
            .visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader)
            .first as? LibraryTopHeaderView
        #expect(unlockedHeader != nil)
        if let unlockedHeader {
            #expect(!unlockedHeader.categoryBarView.isHidden)
            #expect(!unlockedHeader.activeFiltersView.isHidden)
            let categoryFrame = unlockedHeader.convert(
                unlockedHeader.categoryBarView.bounds,
                from: unlockedHeader.categoryBarView
            )
            let filtersFrame = unlockedHeader.convert(
                unlockedHeader.activeFiltersView.bounds,
                from: unlockedHeader.activeFiltersView
            )
            #expect(abs(categoryFrame.height - 44) < 0.01)
            #expect(abs(filtersFrame.height - 38) < 0.01)
            #expect(!categoryFrame.intersects(filtersFrame))
            #expect(abs((unlockedHeader.bounds.height - filtersFrame.maxY) - LibraryTopHeaderView.bottomPadding) < 0.01)
        }

        AppSettings.library.lockLibrary.set(true)
        vc.locked = vc.viewModel.isCategoryLocked()
        #expect(vc.locked)
        vc.updateLockState()
        vc.collectionView.layoutIfNeeded()
        vc.view.layoutIfNeeded()

        let lockedConfig = (vc.collectionView.collectionViewLayout as? UICollectionViewCompositionalLayout)?.configuration
        #expect(lockedConfig?.boundarySupplementaryItems.first?.layoutSize.heightDimension.dimension == 50)
        #expect(vc.forkFilterSortCoordinator.lastTopHeaderHeight == 50)
        #expect(!vc.forkFilterSortCoordinator.isShowingActiveFiltersHeader)

        let lockedHeader = vc.collectionView
            .visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader)
            .first as? LibraryTopHeaderView
        #expect(lockedHeader != nil)
        if let lockedHeader {
            #expect(!lockedHeader.categoryBarView.isHidden)
            #expect(lockedHeader.activeFiltersView.isHidden)
            let categoryFrame = lockedHeader.convert(
                lockedHeader.categoryBarView.bounds,
                from: lockedHeader.categoryBarView
            )
            #expect(abs(categoryFrame.height - 44) < 0.01)
            #expect(abs((lockedHeader.bounds.height - categoryFrame.maxY) - LibraryTopHeaderView.bottomPadding) < 0.01)
        }

        AppSettings.library.lockLibrary.set(false)
        vc.locked = false
        vc.updateLockState()
        vc.collectionView.layoutIfNeeded()
        vc.view.layoutIfNeeded()

        let unlockedAgainConfig = (vc.collectionView.collectionViewLayout as? UICollectionViewCompositionalLayout)?.configuration
        #expect(unlockedAgainConfig?.boundarySupplementaryItems.first?.layoutSize.heightDimension.dimension == 88)
        #expect(vc.forkFilterSortCoordinator.lastTopHeaderHeight == 88)
        #expect(vc.forkFilterSortCoordinator.isShowingActiveFiltersHeader)

        let restoredHeader = vc.collectionView
            .visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader)
            .first as? LibraryTopHeaderView
        #expect(restoredHeader != nil)
        if let restoredHeader {
            #expect(!restoredHeader.categoryBarView.isHidden)
            #expect(!restoredHeader.activeFiltersView.isHidden)
            let categoryFrame = restoredHeader.convert(
                restoredHeader.categoryBarView.bounds,
                from: restoredHeader.categoryBarView
            )
            let filtersFrame = restoredHeader.convert(
                restoredHeader.activeFiltersView.bounds,
                from: restoredHeader.activeFiltersView
            )
            #expect(abs(categoryFrame.height - 44) < 0.01)
            #expect(abs(filtersFrame.height - 38) < 0.01)
            #expect(!categoryFrame.intersects(filtersFrame))
            #expect(abs((restoredHeader.bounds.height - filtersFrame.maxY) - LibraryTopHeaderView.bottomPadding) < 0.01)
        }

        vc.viewModel.categories = []
        vc.viewModel.filters = []
        vc.syncFilterSortUIState()
        #expect(vc.forkFilterSortCoordinator.lastTopHeaderHeight == 0)
        let emptyHeaderConfig = (vc.collectionView.collectionViewLayout as? UICollectionViewCompositionalLayout)?.configuration
        #expect(emptyHeaderConfig?.boundarySupplementaryItems.isEmpty ?? false)

        vc.viewModel.categories = ["Action"]
        vc.syncFilterSortUIState()
        #expect(vc.forkFilterSortCoordinator.lastTopHeaderHeight == 50)
        let healedConfig = (vc.collectionView.collectionViewLayout as? UICollectionViewCompositionalLayout)?.configuration
        #expect(healedConfig?.boundarySupplementaryItems.first?.layoutSize.heightDimension.dimension == 50)
    }

    @MainActor
    @Test func lockedStateDisablesFilterButtonAndPreservesLockButtonOrdering() {
        let snapshot = snapshotUserDefaults()
        defer { restoreUserDefaults(snapshot) }

        let vc = LibraryViewController()
        vc.loadViewIfNeeded()

        AppSettings.library.lockLibrary.set(false)
        vc.viewModel.currentCategory = nil
        vc.locked = false
        vc.updateNavbarItems()
        vc.updateLockState()
        #expect(vc.filterSortBarButton.isEnabled)

        AppSettings.library.lockLibrary.set(true)
        vc.locked = vc.viewModel.isCategoryLocked()
        vc.updateLockState()

        #expect(!vc.filterSortBarButton.isEnabled)
        #expect(!vc.forkFilterSortCoordinator.isShowingActiveFiltersHeader)

        let items = vc.navigationItem.rightBarButtonItems ?? []
        let filterIndex = items.firstIndex(of: vc.filterSortBarButton)
        #expect(filterIndex != nil)
        if let filterIndex, items.indices.contains(filterIndex + 1) {
            #expect(items[filterIndex + 1].title == NSLocalizedString("TOGGLE_LOCK"))
        }

        vc.setEditing(true, animated: false)
        let editingItems = vc.navigationItem.rightBarButtonItems
        vc.updateNavbarLock()
        #expect(vc.navigationItem.rightBarButtonItems == editingItems)
        vc.setEditing(false, animated: false)

        AppSettings.library.lockLibrary.set(false)
        vc.locked = false
        vc.updateLockState()
        #expect(vc.filterSortBarButton.isEnabled)
    }
}
