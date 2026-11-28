//
//  MangaGridCellTests.swift
//  AidokuTests
//
//  Created by Dokuha on 11/28/26.
//

@testable import Aidoku
import Testing
import UIKit

struct MangaGridCellTests {
    @MainActor
    @Test func gridCellPreservesCornerRadiusAndAppliesReadableTitleScrimAndShadow() {
        let cell = MangaGridCell(frame: CGRect(x: 0, y: 0, width: 180, height: 270))
        cell.title = "Test Manga"
        cell.layoutIfNeeded()

        #expect(cell.contentView.layer.cornerRadius == 5)

        var foundGradient: CAGradientLayer?
        var foundTitleLabel: UILabel?
        for subview in cell.contentView.subviews {
            if foundGradient == nil, let gradient = subview.layer.sublayers?.first as? CAGradientLayer {
                foundGradient = gradient
            }
            if foundTitleLabel == nil, let label = subview as? UILabel, label.text == "Test Manga" {
                foundTitleLabel = label
            }
        }

        #expect(foundGradient != nil)
        if let gradient = foundGradient {
            #expect(gradient.locations == [0.48, 0.76, 1])
            let colors = gradient.colors as? [CGColor] ?? []
            #expect(colors.count == 3)
            if colors.count == 3 {
                #expect(abs(colors[0].alpha) < 0.01)
                #expect(abs(colors[1].alpha - 0.45) < 0.01)
                #expect(abs(colors[2].alpha - 0.86) < 0.01)
            }
            #expect(gradient.frame == cell.contentView.bounds)
        }

        cell.frame = CGRect(x: 0, y: 0, width: 150, height: 225)
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        #expect(foundGradient?.frame == cell.contentView.bounds)

        #expect(foundTitleLabel != nil)
        if let titleLabel = foundTitleLabel {
            #expect(titleLabel.textColor == .white)
            #expect(titleLabel.layer.shadowOpacity == 0.5)
            #expect(titleLabel.layer.shadowRadius == 2)
            #expect(titleLabel.layer.shadowOffset == CGSize(width: 0, height: 1))
            #expect(titleLabel.layer.shadowColor != nil)
        }
    }
}
