//
//  ForkLocalization.swift
//  Aidoku
//

import Foundation

enum ForkL10n {
    private static let tableName = "ForkLocalizable"

    static func string(_ key: String) -> String {
        let fallbackValue = fallbackBundle?.localizedString(forKey: key, value: key, table: tableName) ?? key
        return Bundle.main.localizedString(forKey: key, value: fallbackValue, table: tableName)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: Locale.current, arguments: arguments)
    }
}
