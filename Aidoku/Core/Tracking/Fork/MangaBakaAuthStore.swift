//
//  MangaBakaAuthStore.swift
//  Aidoku
//
//  Created by Kodoku on 11/27/26.
//

import Foundation

/// Thread-safe Keychain-backed store for MangaBaka Personal Access Tokens (API Keys).
final class MangaBakaAuthStore: @unchecked Sendable {
    static let shared = MangaBakaAuthStore(
        keychain: SyncKeychainStore(
            service: "\(Bundle.main.bundleIdentifier ?? "io.github.sfai05.Kodoku").mangabaka"
        )
    )
    static let keychainAccount = "mangabaka.apiKey"
    // Kept under `Fork.` so BackupManager and PocketBase Sync never export or overwrite local auth state.
    static let usernameDefaultsKey = "Fork.mangabaka.username"

    private let keychain: SyncKeychainStoreProtocol
    private let userDefaults: UserDefaults
    private let lock = NSLock()
    private var cachedApiKey: String?
    private var hasLoadedKey = false

    init(
        keychain: SyncKeychainStoreProtocol = SyncKeychainStore(),
        userDefaults: UserDefaults = .standard
    ) {
        self.keychain = keychain
        self.userDefaults = userDefaults
    }

    var apiKey: String? {
        lock.lock()
        defer { lock.unlock() }
        if !hasLoadedKey {
            do {
                cachedApiKey = try keychain.readString(account: Self.keychainAccount)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty
                hasLoadedKey = true
            } catch {
                // Keep hasLoadedKey false so transient Keychain read failures do not poison the cache.
                return nil
            }
        }
        return cachedApiKey
    }

    func saveApiKey(_ rawKey: String) throws {
        guard let normalized = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            throw MangaBakaApiError.unauthorized(message: "API Key cannot be empty.")
        }
        lock.lock()
        defer { lock.unlock() }
        try keychain.writeString(normalized, account: Self.keychainAccount)
        cachedApiKey = normalized
        hasLoadedKey = true
    }

    var hasApiKey: Bool {
        apiKey != nil
    }

    var cachedUsername: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return userDefaults.string(forKey: Self.usernameDefaultsKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        }
        set {
            let normalized = newValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
            lock.lock()
            defer { lock.unlock() }
            if let normalized {
                userDefaults.set(normalized, forKey: Self.usernameDefaultsKey)
            } else {
                userDefaults.removeObject(forKey: Self.usernameDefaultsKey)
            }
        }
    }

    func clearApiKey() {
        lock.lock()
        try? keychain.delete(account: Self.keychainAccount)
        cachedApiKey = nil
        hasLoadedKey = true
        lock.unlock()
        cachedUsername = nil
    }
}

enum MangaBakaAuthHelpers {
    private static let formAllowedCharacters: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    /// Encodes form parameters per RFC 3986 so tokens containing `+`, `/`, or `=` are transmitted intact.
    static func formURLEncoded(_ parameters: [String: String]) -> Data? {
        parameters
            .sorted { $0.key < $1.key }
            .map { key, value in
                let escapedKey = key.addingPercentEncoding(withAllowedCharacters: formAllowedCharacters) ?? ""
                let escapedValue = value.addingPercentEncoding(withAllowedCharacters: formAllowedCharacters) ?? ""
                return "\(escapedKey)=\(escapedValue)"
            }
            .joined(separator: "&")
            .data(using: .utf8)
    }

    static func formatDate(_ date: Date, timeZone: TimeZone = .current) -> String {
        if abs(date.timeIntervalSince1970) < 1 {
            return "1970-01-01"
        }
        return makeDateFormatter(timeZone: timeZone).string(from: date)
    }

    static func parseDate(_ raw: String, timeZone: TimeZone = .current) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { return nil }
        let datePrefix = String(trimmed.prefix(10))
        return makeDateFormatter(timeZone: timeZone).date(from: datePrefix)
    }

    static func normalizeChapterNumber(_ value: Float) -> Double {
        (Double(value) * 100).rounded() / 100
    }

    static func parseTotalCount(_ raw: String?) -> Int? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        guard let value = Double(trimmed), value > 0 else {
            return nil
        }
        return Int(floor(value))
    }

    private static func makeDateFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
