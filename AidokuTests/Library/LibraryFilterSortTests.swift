//
//  LibraryFilterSortTests.swift
//  AidokuTests
//
//  Created by Dokuha on 11/27/26.
//

@testable import Aidoku
import AidokuRunner
import SwiftUI
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

        vc.viewModel.categories = []
        vc.viewModel.filterGroups = []
        vc.syncFilterSortUIState()
        #expect(vc.forkFilterSortCoordinator.lastTopHeaderHeight == 0)

        vc.viewModel.filterGroups = [FilterGroup(title: "Ongoing", filters: [])]
        vc.syncFilterSortUIState()
        #expect(vc.forkFilterSortCoordinator.lastTopHeaderHeight == 50)
        let filterGroupHealedConfig = (vc.collectionView.collectionViewLayout as? UICollectionViewCompositionalLayout)?.configuration
        #expect(filterGroupHealedConfig?.boundarySupplementaryItems.first?.layoutSize.heightDimension.dimension == 50)
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

    @Test func detentHeightResultTextAndEmptyHighlightHelpers() {
        #expect(LibraryFilterSortHelpers.preferredSheetDetentHeight(maximumDetentValue: -10) == 0)
        #expect(LibraryFilterSortHelpers.preferredSheetDetentHeight(maximumDetentValue: 0) == 0)

        let compactHeight = LibraryFilterSortHelpers.preferredSheetDetentHeight(maximumDetentValue: 340)
        #expect(abs(compactHeight - 340) < 0.01)

        let smallPhoneHeight = LibraryFilterSortHelpers.preferredSheetDetentHeight(maximumDetentValue: 600)
        #expect(abs(smallPhoneHeight - 460) < 0.01)

        let standardPhoneHeight = LibraryFilterSortHelpers.preferredSheetDetentHeight(maximumDetentValue: 780)
        #expect(abs(standardPhoneHeight - (780 * 0.62)) < 0.01)

        let tallSheetHeight = LibraryFilterSortHelpers.preferredSheetDetentHeight(maximumDetentValue: 1000)
        #expect(abs(tallSheetHeight - 620) < 0.01)

        for maxHeight in [CGFloat(120), 340, 600, 780, 1000] {
            let resolved = LibraryFilterSortHelpers.preferredSheetDetentHeight(maximumDetentValue: maxHeight)
            #expect(resolved > 0 && resolved <= maxHeight)
        }

        #expect(LibraryFilterSortHelpers.resultCountText(for: -5) == ForkL10n.format("LIBRARY_FILTER_RESULTS_COUNT_FORMAT", 0))
        #expect(LibraryFilterSortHelpers.resultCountText(for: 0) == ForkL10n.format("LIBRARY_FILTER_RESULTS_COUNT_FORMAT", 0))
        #expect(LibraryFilterSortHelpers.resultCountText(for: 1) == ForkL10n.string("LIBRARY_FILTER_RESULT_SINGLE"))
        #expect(LibraryFilterSortHelpers.resultCountText(for: 42) == ForkL10n.format("LIBRARY_FILTER_RESULTS_COUNT_FORMAT", 42))

        #expect(!LibraryFilterSortHelpers.shouldHighlightEmptyResults(resultCount: 0, activeFilterCount: 0, isUpdatingResults: false))
        #expect(LibraryFilterSortHelpers.shouldHighlightEmptyResults(resultCount: 0, activeFilterCount: 1, isUpdatingResults: false))
        #expect(!LibraryFilterSortHelpers.shouldHighlightEmptyResults(resultCount: 0, activeFilterCount: 1, isUpdatingResults: true))
        #expect(!LibraryFilterSortHelpers.shouldHighlightEmptyResults(resultCount: 5, activeFilterCount: 1, isUpdatingResults: false))
    }
}

extension LibraryFilterSortTests {
    @MainActor
    @Test func sheetStateTracksCombinedResultCountAndUpdatingFlag() {
        let snapshot = snapshotUserDefaults()
        defer { restoreUserDefaults(snapshot) }

        let viewModel = LibraryViewModel()
        let m1 = MangaInfo(id: MangaIdentifier(sourceKey: "src", mangaKey: "m1"))
        let m2 = MangaInfo(id: MangaIdentifier(sourceKey: "src", mangaKey: "m2"))
        let m3 = MangaInfo(id: MangaIdentifier(sourceKey: "src", mangaKey: "m3"))
        viewModel.pinnedManga = [m1]
        viewModel.manga = [m2, m3]

        let state = LibraryFilterSortState(viewModel: viewModel)
        #expect(state.resultCount == 3)
        #expect(!state.isUpdatingResults)

        viewModel.pinnedManga = []
        viewModel.manga = [m1]
        state.update(from: viewModel, isUpdatingResults: true)
        #expect(state.resultCount == 1)
        #expect(state.isUpdatingResults)

        state.update(from: viewModel, isUpdatingResults: false)
        #expect(state.resultCount == 1)
        #expect(!state.isUpdatingResults)
    }

    @MainActor
    @Test func filterSortSheetPresentationDetentsAndLiveReloadState() async {
        let snapshot = snapshotUserDefaults()
        defer { restoreUserDefaults(snapshot) }

        AppSettings.library.lockLibrary.set(false)
        AppSettings.library.lockedCategories.set([])

        let detents = LibraryViewController.makeFilterSortSheetDetents()
        #expect(detents.count == 2)
        if #available(iOS 16.0, *) {
            #expect(detents[0].identifier == UISheetPresentationController.Detent.Identifier("libraryFilterSortPreferred"))
            #expect(detents[1].identifier == .large)
        }

        let vc = LibraryViewController()
        let nav = UINavigationController(rootViewController: vc)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = nav
        window.makeKeyAndVisible()
        defer {
            vc.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }

        vc.loadViewIfNeeded()
        vc.locked = false
        vc.viewModel.pinnedManga = [MangaInfo(id: MangaIdentifier(sourceKey: "src", mangaKey: "p1"))]
        vc.viewModel.manga = [MangaInfo(id: MangaIdentifier(sourceKey: "src", mangaKey: "r1"))]
        vc.openFilterSortSheet()

        let hostingController = vc.presentedViewController as? UIHostingController<LibraryFilterSortSheet>
        #expect(hostingController != nil)
        #expect(hostingController?.view.backgroundColor == .systemGroupedBackground)
        #expect(hostingController?.sheetPresentationController?.detents.count == 2)
        #expect(hostingController?.sheetPresentationController?.prefersGrabberVisible == true)
        #expect(vc.forkFilterSortCoordinator.activeSheetState?.resultCount == 2)
        #expect(vc.forkFilterSortCoordinator.activeSheetState?.isUpdatingResults == false)

        let initialState = vc.forkFilterSortCoordinator.activeSheetState
        vc.openFilterSortSheet()
        #expect(vc.forkFilterSortCoordinator.activeSheetState === initialState)
        #expect(vc.presentedViewController === hostingController)

        let toggledSortMethod: LibraryViewModel.SortMethod = vc.viewModel.sortMethod == .alphabetical
            ? .lastUpdated
            : .alphabetical
        vc.selectSortFromSheet(method: toggledSortMethod)
        #expect(!vc.forkFilterSortCoordinator.isLoadingResults)
        #expect(vc.forkFilterSortCoordinator.activeSheetState?.isUpdatingResults == false)
        await vc.forkFilterSortCoordinator.activeReloadTask?.value

        vc.toggleFilterFromSheet(method: .downloaded)
        #expect(vc.forkFilterSortCoordinator.isLoadingResults)
        #expect(vc.forkFilterSortCoordinator.activeSheetState?.isUpdatingResults == true)
        await vc.forkFilterSortCoordinator.activeReloadTask?.value
        #expect(!vc.forkFilterSortCoordinator.isLoadingResults)
        #expect(vc.forkFilterSortCoordinator.activeSheetState?.isUpdatingResults == false)
        #expect(
            vc.forkFilterSortCoordinator.activeSheetState?.resultCount
                == vc.viewModel.pinnedManga.count + vc.viewModel.manga.count
        )
    }

    @MainActor
    @Test func activeFiltersHeaderEdgeFadeMaskUpdatesAcrossOverflowAndScroll() {
        let header = LibraryActiveFiltersHeaderView(frame: CGRect(x: 0, y: 0, width: 390, height: 38))
        let singleChip = LibraryFilterSortHelpers.activeFilterChips(
            for: [LibraryFilter(type: .hasUnread, value: nil, exclude: false)],
            resolveSourceName: { $0 }
        )

        header.configure(chips: singleChip, onRemoveFilter: { _ in }, onClearAll: {})
        header.layoutIfNeeded()
        #expect(!header.isEdgeFadeMaskActive)
        #expect(header.edgeFadeState == .none)

        let manyFilters = (1...8).map { index in
            LibraryFilter(type: .category, value: "Long Filter Category \(index)", exclude: index.isMultiple(of: 2))
        }
        let manyChips = LibraryFilterSortHelpers.activeFilterChips(for: manyFilters, resolveSourceName: { $0 })
        header.configure(chips: manyChips, onRemoveFilter: { _ in }, onClearAll: {})
        header.layoutIfNeeded()
        #expect(header.isEdgeFadeMaskActive)
        #expect(abs(header.edgeFadeState.leftStrength) < 0.01)
        #expect(abs(header.edgeFadeState.rightStrength - 1) < 0.01)

        let maxOffsetX = header.scrollView.contentSize.width - header.scrollView.bounds.width
        #expect(maxOffsetX > 40)

        header.scrollView.setContentOffset(CGPoint(x: maxOffsetX / 2, y: 0), animated: false)
        #expect(header.isEdgeFadeMaskActive)
        #expect(abs(header.edgeFadeState.leftStrength - 1) < 0.01)
        #expect(abs(header.edgeFadeState.rightStrength - 1) < 0.01)

        header.scrollView.setContentOffset(CGPoint(x: maxOffsetX, y: 0), animated: false)
        #expect(header.isEdgeFadeMaskActive)
        #expect(abs(header.edgeFadeState.leftStrength - 1) < 0.01)
        #expect(abs(header.edgeFadeState.rightStrength) < 0.01)

        header.configure(chips: singleChip, onRemoveFilter: { _ in }, onClearAll: {})
        header.layoutIfNeeded()
        #expect(!header.isEdgeFadeMaskActive)
        #expect(header.edgeFadeState == .none)
    }

    @Test func popoverPresentationPolicyAndPreferredSize() {
        #expect(LibraryFilterSortHelpers.shouldPresentAsPopover(isPad: true, isRegularWidth: true))
        #expect(!LibraryFilterSortHelpers.shouldPresentAsPopover(isPad: true, isRegularWidth: false))
        #expect(!LibraryFilterSortHelpers.shouldPresentAsPopover(isPad: false, isRegularWidth: true))
        #expect(!LibraryFilterSortHelpers.shouldPresentAsPopover(isPad: false, isRegularWidth: false))
        #expect(LibraryFilterSortHelpers.preferredPopoverContentSize == CGSize(width: 400, height: 540))
    }

    @MainActor
    @Test func filterSortPresentationConfiguresPopoverOnRegularPadAndSheetElsewhere() {
        let snapshot = snapshotUserDefaults()
        defer { restoreUserDefaults(snapshot) }

        AppSettings.library.lockLibrary.set(false)
        AppSettings.library.lockedCategories.set([])

        let vc = LibraryViewController()
        let nav = UINavigationController(rootViewController: vc)
        _ = nav.view
        vc.loadViewIfNeeded()
        vc.updateNavbarItems()
        #expect(vc.navigationItem.rightBarButtonItems?.contains(vc.filterSortBarButton) == true)

        let popoverTarget = UIViewController()
        vc.configureFilterSortPresentation(
            for: popoverTarget,
            horizontalSizeClass: .regular,
            userInterfaceIdiom: .pad
        )
        #expect(popoverTarget.modalPresentationStyle == .popover)
        #expect(popoverTarget.preferredContentSize == LibraryFilterSortHelpers.preferredPopoverContentSize)
        #expect(popoverTarget.popoverPresentationController != nil)
        if #available(iOS 16.0, *) {
            #expect(popoverTarget.popoverPresentationController?.sourceItem as AnyObject? === vc.filterSortBarButton)
            #expect(
                popoverTarget.popoverPresentationController?.adaptiveSheetPresentationController.detents.first?.identifier
                    == UISheetPresentationController.Detent.Identifier("libraryFilterSortPreferred")
            )
        }
        #expect(popoverTarget.popoverPresentationController?.permittedArrowDirections == .any)
        #expect(popoverTarget.popoverPresentationController?.passthroughViews?.isEmpty == true)
        #expect(popoverTarget.popoverPresentationController?.adaptiveSheetPresentationController.detents.count == 2)
        #expect(popoverTarget.popoverPresentationController?.adaptiveSheetPresentationController.prefersGrabberVisible == true)
        #expect(
            popoverTarget.popoverPresentationController?.adaptiveSheetPresentationController
                .prefersScrollingExpandsWhenScrolledToEdge == true
        )

        let compactPadTarget = UIViewController()
        vc.configureFilterSortPresentation(
            for: compactPadTarget,
            horizontalSizeClass: .compact,
            userInterfaceIdiom: .pad
        )
        #expect(compactPadTarget.modalPresentationStyle == .pageSheet)
        #expect(compactPadTarget.sheetPresentationController?.detents.count == 2)
        #expect(compactPadTarget.sheetPresentationController?.prefersGrabberVisible == true)

        let regularPhoneTarget = UIViewController()
        vc.configureFilterSortPresentation(
            for: regularPhoneTarget,
            horizontalSizeClass: .regular,
            userInterfaceIdiom: .phone
        )
        #expect(regularPhoneTarget.modalPresentationStyle == .pageSheet)
        #expect(regularPhoneTarget.sheetPresentationController?.detents.count == 2)

        let originalItems = vc.navigationItem.rightBarButtonItems
        vc.navigationItem.rightBarButtonItems = []
        let missingAnchorTarget = UIViewController()
        vc.configureFilterSortPresentation(
            for: missingAnchorTarget,
            horizontalSizeClass: .regular,
            userInterfaceIdiom: .pad
        )
        #expect(missingAnchorTarget.modalPresentationStyle == .pageSheet)
        vc.navigationItem.rightBarButtonItems = originalItems

        let detachedVC = LibraryViewController()
        detachedVC.loadViewIfNeeded()
        detachedVC.updateNavbarItems()
        let detachedTarget = UIViewController()
        detachedVC.configureFilterSortPresentation(
            for: detachedTarget,
            horizontalSizeClass: .regular,
            userInterfaceIdiom: .pad
        )
        #expect(detachedTarget.modalPresentationStyle == .pageSheet)
    }

    @MainActor
    @Test func activeFiltersHeaderRebuildsChipsAndUpdatesFontsOnDynamicTypeChange() {
        let container = UIViewController()
        let host = UIViewController()
        container.addChild(host)
        container.view.addSubview(host.view)
        host.didMove(toParent: container)

        let header = LibraryActiveFiltersHeaderView(frame: CGRect(x: 0, y: 0, width: 390, height: 38))
        host.view.addSubview(header)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = container
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let chips = LibraryFilterSortHelpers.activeFilterChips(
            for: [
                LibraryFilter(type: .downloaded, value: nil, exclude: false),
                LibraryFilter(type: .tracking, value: nil, exclude: true)
            ],
            resolveSourceName: { $0 }
        )
        header.configure(chips: chips, onRemoveFilter: { _ in }, onClearAll: {})
        window.layoutIfNeeded()
        header.layoutIfNeeded()

        let initialViews = header.arrangedChipViews
        #expect(initialViews.count == 3)

        NotificationCenter.default.post(name: UIContentSizeCategory.didChangeNotification, object: nil)
        let rebuiltViews = header.arrangedChipViews
        #expect(rebuiltViews.count == 3)
        #expect(header.displayedChips == chips)
        #expect(!zip(initialViews, rebuiltViews).contains { $0 === $1 })

        func firstChipFontPointSize() -> CGFloat? {
            guard let title = (header.arrangedChipViews.first as? UIButton)?.configuration?.attributedTitle else {
                return nil
            }
            return (NSAttributedString(title).attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize
        }

        if #available(iOS 17.0, *) {
            host.traitOverrides.preferredContentSizeCategory = .extraSmall
        } else {
            container.setOverrideTraitCollection(
                UITraitCollection(preferredContentSizeCategory: .extraSmall),
                forChild: host
            )
        }
        window.layoutIfNeeded()
        header.layoutIfNeeded()
        let extraSmallSize = firstChipFontPointSize()

        if #available(iOS 17.0, *) {
            host.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraLarge
        } else {
            container.setOverrideTraitCollection(
                UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraLarge),
                forChild: host
            )
        }
        window.layoutIfNeeded()
        header.layoutIfNeeded()
        let enlargedSize = firstChipFontPointSize()

        #expect(extraSmallSize != nil)
        #expect(enlargedSize == 16)
        if let extraSmallSize, let enlargedSize {
            #expect(enlargedSize > extraSmallSize)
        }
    }
}
