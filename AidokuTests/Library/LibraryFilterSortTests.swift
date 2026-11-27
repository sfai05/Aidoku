//
//  LibraryFilterSortTests.swift
//  AidokuTests
//
//  Created by Kodoku on 11/27/26.
//

@testable import Aidoku
import Testing
import UIKit

@Suite struct LibraryFilterSortTests {
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
    @Test func libraryViewControllerUpdatesBarButtonAndLayoutWithBoundaryHeaders() {
        let vc = LibraryViewController()
        vc.loadViewIfNeeded()
        vc.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        vc.view.layoutIfNeeded()

        vc.viewModel.filters = []
        vc.syncFilterSortUIState()
        #expect(!vc.forkFilterSortCoordinator.isShowingActiveFiltersHeader)

        vc.toggleFilterFromSheet(method: .downloaded)
        #expect(vc.viewModel.filters == [LibraryFilter(type: .downloaded, value: nil, exclude: false)])
        #expect(vc.forkFilterSortCoordinator.isShowingActiveFiltersHeader)

        vc.view.layoutIfNeeded()
        let layoutConfig = (vc.collectionView.collectionViewLayout as? UICollectionViewCompositionalLayout)?.configuration
        #expect(layoutConfig?.boundarySupplementaryItems.contains {
            $0.elementKind == LibraryActiveFiltersHeaderView.elementKind
        } ?? false)

        vc.clearAllFilters()
        #expect(vc.viewModel.filters.isEmpty)
        #expect(!vc.forkFilterSortCoordinator.isShowingActiveFiltersHeader)
    }
}
