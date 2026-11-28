//
//  LibraryViewController+ForkCategoryBar.swift
//  Aidoku
//
//  Created by Dokuha on 11/28/26.
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

    func makeCategoryBarRegistration() -> UICollectionView.SupplementaryRegistration<LibraryCategoryBarHeaderView> {
        UICollectionView.SupplementaryRegistration<LibraryCategoryBarHeaderView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, _ in
            guard let self else { return }
            header.delegate = self
            header.configure(with: self.buildCategoryBarSnapshot(), animatedScroll: false)
        }
    }

    func refreshCategoryBarHeader(animatedScroll: Bool = false) {
        let snapshot = buildCategoryBarSnapshot()
        for case let header as LibraryCategoryBarHeaderView in collectionView.visibleSupplementaryViews(
            ofKind: UICollectionView.elementKindSectionHeader
        ) {
            header.delegate = self
            header.configure(with: snapshot, animatedScroll: animatedScroll)
        }
    }
}
