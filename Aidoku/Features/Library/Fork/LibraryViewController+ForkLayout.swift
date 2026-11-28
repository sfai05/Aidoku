//
//  LibraryViewController+ForkLayout.swift
//  Aidoku
//
//  Created by Dokuha on 11/28/26.
//

import UIKit

enum LibraryLayoutMetrics {
    static let standardBottomInset: CGFloat = 10
    static let floatingTabBarBottomInset: CGFloat = 24
    static let stateViewHorizontalPadding: CGFloat = 24

    static func collectionBottomInset(usesFloatingTabBar: Bool) -> CGFloat {
        usesFloatingTabBar ? floatingTabBarBottomInset : standardBottomInset
    }

    static var currentCollectionBottomInset: CGFloat {
        if #available(iOS 26.0, *) {
            return collectionBottomInset(usesFloatingTabBar: true)
        }
        return collectionBottomInset(usesFloatingTabBar: false)
    }
}

// MARK: - Fork: Library layout adjustments
extension LibraryViewController {
    func configureLibraryBottomInset() {
        var inset = collectionView.contentInset
        inset.bottom = LibraryLayoutMetrics.currentCollectionBottomInset
        collectionView.contentInset = inset
    }

    func constrainLibraryStateViews(emptyStackView: UIView, lockedStackView: UIView) {
        let padding = LibraryLayoutMetrics.stateViewHorizontalPadding
        for stateView in [emptyStackView, lockedStackView] {
            stateView.translatesAutoresizingMaskIntoConstraints = false
            let leading = stateView.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor,
                constant: padding
            )
            leading.priority = UILayoutPriority(999)
            let trailing = stateView.trailingAnchor.constraint(
                lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor,
                constant: -padding
            )
            trailing.priority = UILayoutPriority(999)
            NSLayoutConstraint.activate([
                stateView.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
                stateView.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
                leading,
                trailing
            ])
        }
    }
}
