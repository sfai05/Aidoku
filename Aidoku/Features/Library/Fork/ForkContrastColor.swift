//
//  ForkContrastColor.swift
//  Aidoku
//
//  Created by Dokuha on 11/28/26.
//

import SwiftUI
import UIKit

/// Computes contrast-aware foreground colors for solid accent-colored UI elements.
enum ForkContrastColor {
    /// Relative luminance threshold above which dark foreground text provides better legibility.
    /// Preserves white text on saturated iOS accents (`.systemPink`, `.systemRed`, `.systemBlue`,
    /// `.systemPurple`, `.systemIndigo`) while switching to dark text on bright/pastel accents
    /// (`.systemYellow`, `.systemMint`, `.systemOrange`, `.systemGreen`, lime, white).
    static let lightBackgroundLuminanceThreshold: CGFloat = 0.35

    /// Computes WCAG 2.1 sRGB relative luminance in `0...1` from sRGB channel values.
    static func relativeLuminance(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGFloat {
        0.2126 * linearize(red) + 0.7152 * linearize(green) + 0.0722 * linearize(blue)
    }

    /// Resolves sRGB relative luminance for a `UIColor` under the given `UITraitCollection`.
    static func relativeLuminance(
        of color: UIColor,
        traitCollection: UITraitCollection = .current
    ) -> CGFloat? {
        let resolved = color.resolvedColor(with: traitCollection)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return relativeLuminance(red: red, green: green, blue: blue)
        }
        var white: CGFloat = 0
        if resolved.getWhite(&white, alpha: &alpha) {
            return relativeLuminance(red: white, green: white, blue: white)
        }
        if
            let srgb = CGColorSpace(name: CGColorSpace.sRGB),
            let converted = resolved.cgColor.converted(to: srgb, intent: .defaultIntent, options: nil),
            let components = converted.components,
            components.count >= 3
        {
            return relativeLuminance(red: components[0], green: components[1], blue: components[2])
        }
        return nil
    }

    static func prefersDarkForeground(
        for color: UIColor,
        traitCollection: UITraitCollection = .current
    ) -> Bool {
        guard let luminance = relativeLuminance(of: color, traitCollection: traitCollection) else {
            return false
        }
        return luminance > lightBackgroundLuminanceThreshold
    }

    static func uiForegroundColor(
        for backgroundColor: UIColor,
        traitCollection: UITraitCollection = .current
    ) -> UIColor {
        prefersDarkForeground(for: backgroundColor, traitCollection: traitCollection) ? .black : .white
    }

    static func traitCollection(
        colorScheme: ColorScheme,
        highContrast: Bool = false
    ) -> UITraitCollection {
        let style: UIUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        let contrast: UIAccessibilityContrast = highContrast ? .high : .normal
        if #available(iOS 17.0, *) {
            return UITraitCollection { traits in
                traits.userInterfaceStyle = style
                traits.accessibilityContrast = contrast
            }
        }
        return UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: style),
            UITraitCollection(accessibilityContrast: contrast)
        ])
    }

    static func swiftUIForegroundColor(
        for backgroundColor: UIColor,
        colorScheme: ColorScheme,
        highContrast: Bool = false
    ) -> Color {
        let traits = traitCollection(colorScheme: colorScheme, highContrast: highContrast)
        return prefersDarkForeground(for: backgroundColor, traitCollection: traits) ? .black : .white
    }

    private static func linearize(_ component: CGFloat) -> CGFloat {
        let clamped = min(max(component, 0), 1)
        if clamped <= 0.04045 {
            return clamped / 12.92
        }
        return pow((clamped + 0.055) / 1.055, 2.4)
    }
}
