//
//  LibraryViewController+ForkLayout.swift
//  Aidoku
//
//  Created by Dokuha on 11/28/26.
//

import CoreGraphics
import UIKit

enum LibraryLayoutMetrics {
    static let standardBottomInset: CGFloat = 10
    static let floatingTabBarBottomInset: CGFloat = 24

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
}
