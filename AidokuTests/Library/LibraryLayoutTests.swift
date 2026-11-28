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

    @MainActor
    @Test func emptyAndLockedStateViewsCenterWithinSafeAreaAndRespectHorizontalPadding() {
        let vc = LibraryViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = vc
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        vc.additionalSafeAreaInsets = UIEdgeInsets(top: 120, left: 20, bottom: 40, right: 0)
        vc.loadViewIfNeeded()

        let emptyView = vc.view.subviews.first { $0 is EmptyPageStackView } as? EmptyPageStackView
        let lockedView = vc.view.subviews.first { $0 is LockedPageStackView } as? LockedPageStackView
        #expect(emptyView != nil)
        #expect(lockedView != nil)

        emptyView?.text = "Try adjusting or clearing your active filters so matching titles "
            + "in your library become visible again across all categories."
        lockedView?.text = "Library Locked"

        window.layoutIfNeeded()
        vc.view.layoutIfNeeded()

        let safeFrame = vc.view.safeAreaLayoutGuide.layoutFrame
        #expect(abs(safeFrame.midY - vc.view.bounds.midY) > 10)
        #expect(abs(safeFrame.midX - vc.view.bounds.midX) > 5)

        for stateView in [emptyView, lockedView].compactMap({ $0 }) {
            #expect(abs(stateView.center.x - safeFrame.midX) < 0.5)
            #expect(abs(stateView.center.y - safeFrame.midY) < 0.5)
            #expect(stateView.frame.minX >= safeFrame.minX + LibraryLayoutMetrics.stateViewHorizontalPadding - 0.5)
            #expect(stateView.frame.maxX <= safeFrame.maxX - LibraryLayoutMetrics.stateViewHorizontalPadding + 0.5)
        }

        let zeroVC = LibraryViewController()
        zeroVC.loadViewIfNeeded()
        zeroVC.view.frame = .zero
        zeroVC.view.layoutIfNeeded()

        let zeroEmpty = zeroVC.view.subviews.first { $0 is EmptyPageStackView }
        let zeroLocked = zeroVC.view.subviews.first { $0 is LockedPageStackView }
        #expect(zeroEmpty != nil)
        #expect(zeroLocked != nil)
        if let zeroEmpty, let zeroLocked {
            #expect(!zeroEmpty.frame.width.isNaN && !zeroEmpty.frame.height.isNaN)
            #expect(!zeroLocked.frame.width.isNaN && !zeroLocked.frame.height.isNaN)
        }
    }
}
