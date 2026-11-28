//
//  LibraryViewModel+ForkFilterSort.swift
//  Aidoku
//
//  Created by Kodoku on 11/27/26.
//

import Foundation

// MARK: - Fork: Synchronous filter/sort state mutations for instant UI feedback
extension LibraryViewModel {
    func applyFilterToggleMutation(method: LibraryFilter.FilterMethod, value: String? = nil) {
        filters = LibraryFilterSortHelpers.toggling(method: method, value: value, in: filters)
    }

    func applyFilterRemovalMutation(method: LibraryFilter.FilterMethod, value: String? = nil) {
        filters = LibraryFilterSortHelpers.removing(method: method, value: value, from: filters)
    }

    func clearAllFiltersMutation() {
        guard !filters.isEmpty else { return }
        filters = []
    }

    // Persists sort settings synchronously so serialized coordinator reloads do not clash with upstream `setSort`.
    @discardableResult
    func applySortMutation(method: SortMethod, ascending: Bool) -> Bool {
        guard sortMethod != method || sortAscending != ascending else {
            return false
        }
        if sortAscending != ascending {
            sortAscending = ascending
            AppSettings.library.sortAscending.set(sortAscending)
        }
        if sortMethod != method {
            sortMethod = method
            AppSettings.library.sortOption.set(sortMethod.rawValue)
        }
        return true
    }
}
