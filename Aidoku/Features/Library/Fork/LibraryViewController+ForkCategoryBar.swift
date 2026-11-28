//
//  LibraryViewController+ForkCategoryBar.swift
//  Aidoku
//
//  Created by Kodoku on 11/28/26.
//

import UIKit

// MARK: - Fork: Horizontal scrollable category pill bar
extension LibraryViewController {
    func buildCategoryBarSnapshot() -> LibraryCategoryBarSnapshot {
        LibraryCategoryBarBuilder.build(
            LibraryCategoryBarInput(
                showUncategorized: AppSettings.library.showUncategorizedCategory.get(),
                categories: viewModel.categories,
                filterGroupTitles: viewModel.filterGroups.map(\.title),
                currentCategory: viewModel.currentCategory,
                lockLibraryEnabled: AppSettings.library.lockLibrary.get(),
                lockedCategories: AppSettings.library.lockedCategories.get()
            )
        )
    }

    func makeTopHeaderRegistration() -> UICollectionView.SupplementaryRegistration<LibraryTopHeaderView> {
        UICollectionView.SupplementaryRegistration<LibraryTopHeaderView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, _ in
            guard let self else { return }
            let showCategories = !self.viewModel.categories.isEmpty || !self.viewModel.filterGroups.isEmpty
            let showActiveFilters = !self.viewModel.filters.isEmpty && !self.locked
            header.configureVisibility(showCategories: showCategories, showActiveFilters: showActiveFilters)
            header.categoryBarView.delegate = self
            if showCategories {
                header.categoryBarView.configure(with: self.buildCategoryBarSnapshot(), animatedScroll: false)
            }
            if showActiveFilters {
                self.configureActiveFiltersHeader(header.activeFiltersView)
            }
        }
    }

    func refreshCategoryBarHeader(animatedScroll: Bool = false) {
        let showCategories = !viewModel.categories.isEmpty || !viewModel.filterGroups.isEmpty
        let showActiveFilters = !viewModel.filters.isEmpty && !locked
        let snapshot = showCategories ? buildCategoryBarSnapshot() : nil
        for case let header as LibraryTopHeaderView in collectionView.visibleSupplementaryViews(
            ofKind: UICollectionView.elementKindSectionHeader
        ) {
            header.configureVisibility(showCategories: showCategories, showActiveFilters: showActiveFilters)
            header.categoryBarView.delegate = self
            if let snapshot {
                header.categoryBarView.configure(with: snapshot, animatedScroll: animatedScroll)
            }
            if showActiveFilters {
                configureActiveFiltersHeader(header.activeFiltersView)
            }
        }
    }
}
