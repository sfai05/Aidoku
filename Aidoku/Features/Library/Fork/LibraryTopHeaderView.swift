//
//  LibraryTopHeaderView.swift
//  Aidoku
//
//  Created by Dokuha on 11/28/26.
//

import UIKit

/// Composite top supplementary header stacking the category pill bar above active filter chips.
final class LibraryTopHeaderView: UICollectionReusableView {
    static let categoryBarHeight: CGFloat = 44
    static let activeFiltersHeight: CGFloat = 38
    static let bottomPadding: CGFloat = 6

    static func totalHeight(showCategories: Bool, showActiveFilters: Bool) -> CGFloat {
        let contentHeight = (showCategories ? categoryBarHeight : 0)
            + (showActiveFilters ? activeFiltersHeight : 0)
        return contentHeight > 0 ? contentHeight + bottomPadding : 0
    }

    let categoryBarView = LibraryCategoryBarHeaderView()
    let activeFiltersView = LibraryActiveFiltersHeaderView()

    private let stackView = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureViews()
        constrainViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configureVisibility(showCategories: Bool, showActiveFilters: Bool) {
        categoryBarView.isHidden = !showCategories
        activeFiltersView.isHidden = !showActiveFilters
    }
}

private extension LibraryTopHeaderView {
    func configureViews() {
        stackView.axis = .vertical
        stackView.alignment = .fill
        stackView.distribution = .fill
        stackView.spacing = 0
        addSubview(stackView)

        stackView.addArrangedSubview(categoryBarView)
        stackView.addArrangedSubview(activeFiltersView)
    }

    func constrainViews() {
        stackView.translatesAutoresizingMaskIntoConstraints = false
        categoryBarView.translatesAutoresizingMaskIntoConstraints = false
        activeFiltersView.translatesAutoresizingMaskIntoConstraints = false

        let categoryHeight = categoryBarView.heightAnchor.constraint(equalToConstant: Self.categoryBarHeight)
        categoryHeight.priority = UILayoutPriority(999)

        let filtersHeight = activeFiltersView.heightAnchor.constraint(equalToConstant: Self.activeFiltersHeight)
        filtersHeight.priority = UILayoutPriority(999)

        let stackBottom = stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.bottomPadding)
        stackBottom.priority = UILayoutPriority(998)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackBottom,
            categoryHeight,
            filtersHeight
        ])
    }
}
