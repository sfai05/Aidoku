//
//  LibraryFilterSortModels.swift
//  Aidoku
//
//  Created by Dokuha on 11/27/26.
//

import CoreGraphics
import Foundation

/// Represents the three-state cycle of a library filter option.
enum LibraryFilterTriState: Equatable, Sendable {
    case off
    case included
    case excluded
}

/// Presentation model for a removable chip in the library active-filters strip.
struct LibraryActiveFilterChip: Identifiable, Equatable, Sendable {
    let id: String
    let filter: LibraryFilter
    let title: String
    let isExcluded: Bool
}

/// Pure helpers for mutating and summarizing library filters and sort options.
enum LibraryFilterSortHelpers {
    static func state(
        for method: LibraryFilter.FilterMethod,
        value: String? = nil,
        in filters: [LibraryFilter]
    ) -> LibraryFilterTriState {
        guard let filter = filters.first(where: { $0.type == method && $0.value == value }) else {
            return .off
        }
        return filter.exclude ? .excluded : .included
    }

    static func toggling(
        method: LibraryFilter.FilterMethod,
        value: String? = nil,
        in filters: [LibraryFilter]
    ) -> [LibraryFilter] {
        var next = filters
        if let index = next.firstIndex(where: { $0.type == method && $0.value == value }) {
            if next[index].exclude {
                next.remove(at: index)
            } else {
                next[index].exclude = true
            }
        } else {
            next.append(LibraryFilter(type: method, value: value, exclude: false))
        }
        return next
    }

    static func removing(
        method: LibraryFilter.FilterMethod,
        value: String? = nil,
        from filters: [LibraryFilter]
    ) -> [LibraryFilter] {
        filters.filter { !($0.type == method && $0.value == value) }
    }

    static func nextSort(
        currentMethod: LibraryViewModel.SortMethod,
        currentAscending: Bool,
        tappedMethod: LibraryViewModel.SortMethod
    ) -> (method: LibraryViewModel.SortMethod, ascending: Bool) {
        if currentMethod == tappedMethod {
            return (tappedMethod, !currentAscending)
        }
        return (tappedMethod, false)
    }

    static func isVisuallyAscending(
        method: LibraryViewModel.SortMethod,
        sortAscending: Bool
    ) -> Bool {
        // Alphabetical uses `sortAscending == false` for A -> Z ascending order.
        method == .alphabetical ? !sortAscending : sortAscending
    }

    static func mergedFilterOptions(
        available: [String],
        activeFilters: [LibraryFilter],
        method: LibraryFilter.FilterMethod
    ) -> [String] {
        var result = available
        var seen = Set(available)
        for filter in activeFilters where filter.type == method {
            guard let value = filter.value, seen.insert(value).inserted else { continue }
            result.append(value)
        }
        return result
    }

    static func activeFilterChips(
        for filters: [LibraryFilter],
        resolveSourceName: (String) -> String
    ) -> [LibraryActiveFilterChip] {
        filters.map { filter in
            let baseTitle: String = switch filter.type {
                case .downloaded, .tracking, .hasUnread, .started, .completed:
                    filter.type.title
                case .contentRating:
                    filter.value.flatMap(MangaContentRating.init(stringValue:))?.title ?? filter.value ?? filter.type.title
                case .source:
                    filter.value.map(resolveSourceName) ?? filter.type.title
                case .category:
                    filter.value ?? filter.type.title
            }
            let displayTitle = filter.exclude
                ? String(format: NSLocalizedString("NOT_%@"), baseTitle)
                : baseTitle
            let id = "\(filter.type.rawValue)|\(filter.value ?? "")|\(filter.exclude)"
            return LibraryActiveFilterChip(
                id: id,
                filter: filter,
                title: displayTitle,
                isExcluded: filter.exclude
            )
        }
    }

    static func preferredSheetDetentHeight(maximumDetentValue: CGFloat) -> CGFloat {
        guard maximumDetentValue > 0 else { return 0 }
        let proportional = maximumDetentValue * 0.62
        let minimumComfortable = min(460, maximumDetentValue)
        return min(maximumDetentValue, max(proportional, minimumComfortable))
    }

    /// Matches phone sheet inner width (~368pt with 16pt horizontal padding) so Sort and chip rows avoid clipping.
    static let preferredPopoverContentSize = CGSize(width: 400, height: 540)

    static func shouldPresentAsPopover(
        isPad: Bool,
        isRegularWidth: Bool
    ) -> Bool {
        isPad && isRegularWidth
    }

    static func resultCountText(for count: Int) -> String {
        let clamped = max(0, count)
        if clamped == 1 {
            return ForkL10n.string("LIBRARY_FILTER_RESULT_SINGLE")
        }
        return ForkL10n.format("LIBRARY_FILTER_RESULTS_COUNT_FORMAT", clamped)
    }

    static func shouldHighlightEmptyResults(
        resultCount: Int,
        activeFilterCount: Int,
        isUpdatingResults: Bool
    ) -> Bool {
        resultCount == 0 && activeFilterCount > 0 && !isUpdatingResults
    }
}

/// Observable bridge keeping the presented Filter & Sort sheet synchronized with `LibraryViewModel`.
@MainActor
final class LibraryFilterSortState: ObservableObject {
    @Published var filters: [LibraryFilter]
    @Published var sortMethod: LibraryViewModel.SortMethod
    @Published var sortAscending: Bool
    @Published var sourceKeys: [String]
    @Published var categories: [String]
    @Published var isViewingFilterGroup: Bool
    @Published var activeFilterGroupTitle: String?
    @Published var resultCount: Int
    @Published var isUpdatingResults: Bool

    var activeFilterCount: Int {
        filters.count
    }

    init(viewModel: LibraryViewModel, isUpdatingResults: Bool = false) {
        let groupTitle = Self.resolveFilterGroupTitle(from: viewModel)
        self.filters = viewModel.filters
        self.sortMethod = viewModel.sortMethod
        self.sortAscending = viewModel.sortAscending
        self.sourceKeys = viewModel.sourceKeys
        self.categories = viewModel.categories
        self.isViewingFilterGroup = groupTitle != nil
        self.activeFilterGroupTitle = groupTitle
        self.resultCount = Self.resolveResultCount(from: viewModel)
        self.isUpdatingResults = isUpdatingResults
    }

    func update(from viewModel: LibraryViewModel, isUpdatingResults: Bool = false) {
        let groupTitle = Self.resolveFilterGroupTitle(from: viewModel)
        filters = viewModel.filters
        sortMethod = viewModel.sortMethod
        sortAscending = viewModel.sortAscending
        sourceKeys = viewModel.sourceKeys
        categories = viewModel.categories
        isViewingFilterGroup = groupTitle != nil
        activeFilterGroupTitle = groupTitle
        resultCount = Self.resolveResultCount(from: viewModel)
        self.isUpdatingResults = isUpdatingResults
    }

    private static func resolveFilterGroupTitle(from viewModel: LibraryViewModel) -> String? {
        guard let title = viewModel.currentCategory else { return nil }
        return viewModel.filterGroups.contains { $0.title == title } ? title : nil
    }

    private static func resolveResultCount(from viewModel: LibraryViewModel) -> Int {
        viewModel.pinnedManga.count + viewModel.manga.count
    }
}
