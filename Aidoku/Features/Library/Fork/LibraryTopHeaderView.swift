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

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
            categoryHeight,
            filtersHeight
        ])
    }
}
