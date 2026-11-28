//
//  LibraryLayoutTests.swift
//  AidokuTests
//
//  Created by Dokuha on 11/28/26.
//

@testable import Aidoku
import Testing
import UIKit

struct LibraryLayoutTests {
    @Test func collectionBottomInsetAdaptsForFloatingTabBar() {
        #expect(LibraryLayoutMetrics.collectionBottomInset(usesFloatingTabBar: false) == 10)
        #expect(LibraryLayoutMetrics.collectionBottomInset(usesFloatingTabBar: true) == 24)

        if #available(iOS 26.0, *) {
            #expect(LibraryLayoutMetrics.currentCollectionBottomInset == 24)
        } else {
            #expect(LibraryLayoutMetrics.currentCollectionBottomInset == 10)
        }
    }

    @MainActor
    @Test func libraryViewControllerAppliesConfiguredBottomInset() {
        let vc = LibraryViewController()
        vc.loadViewIfNeeded()

        #expect(vc.collectionView.contentInset.top == 0)
        #expect(vc.collectionView.contentInset.left == 0)
        #expect(vc.collectionView.contentInset.right == 0)
        #expect(vc.collectionView.contentInset.bottom == LibraryLayoutMetrics.currentCollectionBottomInset)
    }
}
