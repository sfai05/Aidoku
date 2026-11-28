//
//  ForkContrastColorTests.swift
//  AidokuTests
//
//  Created by Dokuha on 11/28/26.
//

@testable import Aidoku
import SwiftUI
import Testing
import UIKit

struct ForkContrastColorTests {
    @Test func relativeLuminanceAndForegroundSelectionForStandardAndLightAccents() {
        #expect(ForkContrastColor.relativeLuminance(red: 0, green: 0, blue: 0) == 0)
        #expect(ForkContrastColor.relativeLuminance(red: 1, green: 1, blue: 1) == 1)

        let lightTraits = UITraitCollection(userInterfaceStyle: .light)
        let darkTraits = UITraitCollection(userInterfaceStyle: .dark)

        let saturatedAccents: [UIColor] = [
            .black,
            .systemPink,
            .systemRed,
            .systemBlue,
            .systemIndigo,
            .systemPurple
        ]
        for color in saturatedAccents {
            #expect(ForkContrastColor.uiForegroundColor(for: color, traitCollection: lightTraits) == .white)
            #expect(ForkContrastColor.uiForegroundColor(for: color, traitCollection: darkTraits) == .white)
        }

        let lime = UIColor(red: 198 / 255, green: 1, blue: 0, alpha: 1)
        let pastelPink = UIColor(red: 1, green: 179 / 255, blue: 198 / 255, alpha: 1)
        let brightAccents: [UIColor] = [.white, .systemYellow, lime, pastelPink]
        for color in brightAccents {
            #expect(ForkContrastColor.uiForegroundColor(for: color, traitCollection: lightTraits) == .black)
            #expect(ForkContrastColor.uiForegroundColor(for: color, traitCollection: darkTraits) == .black)
        }

        #expect(ForkContrastColor.uiForegroundColor(for: UIColor(white: 0.9, alpha: 1)) == .black)
        #expect(ForkContrastColor.uiForegroundColor(for: UIColor(white: 0.1, alpha: 1)) == .white)

        let dynamicAccent = UIColor { traits in
            traits.userInterfaceStyle == .dark ? .systemYellow : .systemIndigo
        }
        #expect(ForkContrastColor.uiForegroundColor(for: dynamicAccent, traitCollection: lightTraits) == .white)
        #expect(ForkContrastColor.uiForegroundColor(for: dynamicAccent, traitCollection: darkTraits) == .black)

        #expect(ForkContrastColor.relativeLuminance(of: UIColor(Color.accentColor), traitCollection: lightTraits) != nil)
        #expect(ForkContrastColor.swiftUIForegroundColor(for: UIColor(Color.accentColor), colorScheme: .light) == .white)
        #expect(ForkContrastColor.swiftUIForegroundColor(for: UIColor(Color.accentColor), colorScheme: .dark) == .white)
        #expect(ForkContrastColor.swiftUIForegroundColor(for: .systemYellow, colorScheme: .dark) == .black)
    }
}
