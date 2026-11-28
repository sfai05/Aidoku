//
//  LibraryCategoryBarModels.swift
//  Aidoku
//
//  Created by Kodoku on 11/28/26.
//

import Foundation

/// Kind of selectable item in the horizontal library category pill bar.
enum LibraryCategoryItemKind: Equatable, Sendable {
    case all
    case uncategorized
    case category
    case filterGroup
}

/// Presentation model for one capsule pill in `LibraryCategoryBarHeaderView`.
struct LibraryCategoryBarItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let kind: LibraryCategoryItemKind
    let indexPath: IndexPath
    let isLocked: Bool
    let isSelected: Bool
}

/// Logical grouping of pills rendered in the bar and its quick-jump menu.
struct LibraryCategoryBarSection: Equatable, Sendable {
    let title: String?
    let items: [LibraryCategoryBarItem]
}

/// Complete snapshot driving `LibraryCategoryBarHeaderView` and its quick-jump menu.
struct LibraryCategoryBarSnapshot: Equatable, Sendable {
    let sections: [LibraryCategoryBarSection]
    let selectedIndexPath: IndexPath

    var allItems: [LibraryCategoryBarItem] {
        sections.flatMap(\.items)
    }

    var totalItemCount: Int {
        sections.reduce(0) { $0 + $1.items.count }
    }

    var shouldShowQuickJumpButton: Bool {
        totalItemCount >= 5
    }
}

/// Input parameters for constructing a `LibraryCategoryBarSnapshot`.
struct LibraryCategoryBarInput: Equatable, Sendable {
    let showUncategorized: Bool
    let categories: [String]
    let filterGroupTitles: [String]
    let currentCategory: String?
    let lockLibraryEnabled: Bool
    let lockedCategories: [String]
    /// Reserved hook for filtering hidden/secret categories while preserving underlying section/row indices.
    var hiddenCategories: Set<String> = []
}

/// Pure builder converting library category/filter-group state into pill bar sections.
enum LibraryCategoryBarBuilder {
    static func build(_ input: LibraryCategoryBarInput) -> LibraryCategoryBarSnapshot {
        let selectedIndexPath = resolveSelectedIndexPath(input)
        let lockedSet = input.lockLibraryEnabled ? Set(input.lockedCategories) : []

        var sections: [LibraryCategoryBarSection] = []

        var builtInItems: [LibraryCategoryBarItem] = [
            LibraryCategoryBarItem(
                id: "all",
                title: NSLocalizedString("ALL"),
                kind: .all,
                indexPath: IndexPath(row: 0, section: 0),
                isLocked: input.lockLibraryEnabled,
                isSelected: selectedIndexPath == IndexPath(row: 0, section: 0)
            )
        ]
        if input.showUncategorized {
            let indexPath = IndexPath(row: 1, section: 0)
            builtInItems.append(
                LibraryCategoryBarItem(
                    id: "uncategorized",
                    title: NSLocalizedString("UNCATEGORIZED"),
                    kind: .uncategorized,
                    indexPath: indexPath,
                    isLocked: false,
                    isSelected: selectedIndexPath == indexPath
                )
            )
        }
        sections.append(LibraryCategoryBarSection(title: nil, items: builtInItems))

        let categoryItems: [LibraryCategoryBarItem] = input.categories.enumerated().compactMap { index, title in
            guard !input.hiddenCategories.contains(title) else { return nil }
            let indexPath = IndexPath(row: index, section: 1)
            return LibraryCategoryBarItem(
                id: "category:\(index):\(title)",
                title: title,
                kind: .category,
                indexPath: indexPath,
                isLocked: input.lockLibraryEnabled && lockedSet.contains(title),
                isSelected: selectedIndexPath == indexPath
            )
        }
        if !categoryItems.isEmpty {
            sections.append(
                LibraryCategoryBarSection(
                    title: NSLocalizedString("CATEGORIES"),
                    items: categoryItems
                )
            )
        }

        let filterGroupSection = input.categories.isEmpty ? 1 : 2
        let filterGroupItems: [LibraryCategoryBarItem] = input.filterGroupTitles.enumerated().compactMap { index, title in
            guard !input.hiddenCategories.contains(title) else { return nil }
            let indexPath = IndexPath(row: index, section: filterGroupSection)
            return LibraryCategoryBarItem(
                id: "filterGroup:\(index):\(title)",
                title: title,
                kind: .filterGroup,
                indexPath: indexPath,
                isLocked: input.lockLibraryEnabled && lockedSet.contains(title),
                isSelected: selectedIndexPath == indexPath
            )
        }
        if !filterGroupItems.isEmpty {
            sections.append(
                LibraryCategoryBarSection(
                    title: NSLocalizedString("FILTER_GROUPS"),
                    items: filterGroupItems
                )
            )
        }

        return LibraryCategoryBarSnapshot(sections: sections, selectedIndexPath: selectedIndexPath)
    }

    private static func resolveSelectedIndexPath(_ input: LibraryCategoryBarInput) -> IndexPath {
        guard let currentCategory = input.currentCategory else {
            return IndexPath(row: 0, section: 0)
        }
        if
            let index = input.categories.firstIndex(of: currentCategory),
            !input.hiddenCategories.contains(currentCategory)
        {
            return IndexPath(row: index, section: 1)
        }
        if
            let index = input.filterGroupTitles.firstIndex(of: currentCategory),
            !input.hiddenCategories.contains(currentCategory)
        {
            return IndexPath(row: index, section: input.categories.isEmpty ? 1 : 2)
        }
        if currentCategory.isEmpty && input.showUncategorized {
            return IndexPath(row: 1, section: 0)
        }
        return IndexPath(row: 0, section: 0)
    }
}
