//
//  HorizontalEdgeFadeMask.swift
//  Aidoku
//
//  Created by Dokuha on 11/28/26.
//

import CoreGraphics
import UIKit

/// Normalized fade strengths for the horizontal scroll container edges.
struct HorizontalEdgeFadeState: Equatable, Sendable {
    let leftStrength: CGFloat
    let rightStrength: CGFloat
    let fadeFraction: CGFloat

    var isActive: Bool {
        fadeFraction > 0 && (leftStrength > 0 || rightStrength > 0)
    }

    static let none = HorizontalEdgeFadeState(leftStrength: 0, rightStrength: 0, fadeFraction: 0)
}

/// Pure geometry calculations for dynamic horizontal edge fade masks.
enum HorizontalEdgeFadeCalculator {
    static let defaultFadeWidth: CGFloat = 20
    static let overflowEpsilon: CGFloat = 0.5
    static let maxFadeFraction: CGFloat = 0.25

    static func state(
        contentOffsetX: CGFloat,
        contentWidth: CGFloat,
        viewportWidth: CGFloat,
        fadeWidth: CGFloat = defaultFadeWidth
    ) -> HorizontalEdgeFadeState {
        guard viewportWidth > 0, fadeWidth > 0 else {
            return .none
        }
        let maxOffsetX = contentWidth - viewportWidth
        guard maxOffsetX > overflowEpsilon else {
            return .none
        }

        let clampedLeftDistance = min(fadeWidth, max(0, contentOffsetX))
        let clampedRightDistance = min(fadeWidth, max(0, maxOffsetX - contentOffsetX))
        let leftStrength = clampedLeftDistance / fadeWidth
        let rightStrength = clampedRightDistance / fadeWidth
        let fadeFraction = min(maxFadeFraction, fadeWidth / viewportWidth)

        guard fadeFraction > 0, leftStrength > 0 || rightStrength > 0 else {
            return .none
        }
        return HorizontalEdgeFadeState(
            leftStrength: leftStrength,
            rightStrength: rightStrength,
            fadeFraction: fadeFraction
        )
    }
}

/// Manages a non-animated `CAGradientLayer` mask for a horizontal scroll container view.
@MainActor
final class HorizontalEdgeFadeMaskController {
    private let fadeWidth: CGFloat
    private let gradientLayer: CAGradientLayer
    private(set) var currentState: HorizontalEdgeFadeState = .none

    init(fadeWidth: CGFloat = HorizontalEdgeFadeCalculator.defaultFadeWidth) {
        self.fadeWidth = fadeWidth
        let layer = CAGradientLayer()
        layer.startPoint = CGPoint(x: 0, y: 0.5)
        layer.endPoint = CGPoint(x: 1, y: 0.5)
        self.gradientLayer = layer
    }

    @discardableResult
    func update(containerView: UIView, scrollView: UIScrollView) -> HorizontalEdgeFadeState {
        let inset = scrollView.adjustedContentInset
        let normalizedOffsetX = scrollView.contentOffset.x + inset.left
        let totalContentWidth = inset.left + scrollView.contentSize.width + inset.right
        let viewportWidth = scrollView.bounds.width

        let state = HorizontalEdgeFadeCalculator.state(
            contentOffsetX: normalizedOffsetX,
            contentWidth: totalContentWidth,
            viewportWidth: viewportWidth,
            fadeWidth: fadeWidth
        )
        currentState = state

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard state.isActive else {
            if containerView.layer.mask != nil {
                containerView.layer.mask = nil
            }
            return state
        }

        let opaque = UIColor.black.cgColor
        let leftEdge = UIColor.black.withAlphaComponent(1 - state.leftStrength).cgColor
        let rightEdge = UIColor.black.withAlphaComponent(1 - state.rightStrength).cgColor
        let fraction = Double(state.fadeFraction)

        gradientLayer.frame = containerView.bounds
        gradientLayer.locations = [
            0,
            NSNumber(value: fraction),
            NSNumber(value: 1 - fraction),
            1
        ]
        gradientLayer.colors = [leftEdge, opaque, opaque, rightEdge]
        if containerView.layer.mask !== gradientLayer {
            containerView.layer.mask = gradientLayer
        }
        return state
    }
}
