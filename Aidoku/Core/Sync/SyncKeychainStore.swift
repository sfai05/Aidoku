//
//  SyncKeychainStore.swift
//  Aidoku
//

import Foundation
import Security

protocol SyncKeychainStoreProtocol: Sendable {
    func readData(account: String) throws -> Data?
    func writeData(_ data: Data, account: String) throws
    func delete(account: String) throws
}

extension SyncKeychainStoreProtocol {
    func readString(account: String) throws -> String? {
        guard let data = try readData(account: account) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else {
            throw SyncError.persistenceError("Failed to decode UTF-8 Keychain value for \(account)")
        }
        return value
    }

    func writeString(_ value: String, account: String) throws {
        try writeData(Data(value.utf8), account: account)
    }
}

enum SyncKeychainAccount {
    static let pocketBaseAuthToken = "pocketbase.authToken"
    static let pocketBaseUserId = "pocketbase.userId"
    static let pocketBaseUserEmail = "pocketbase.userEmail"
}

final class SyncKeychainStore: SyncKeychainStoreProtocol {
    let service: String

    init(service: String = "\(Bundle.main.bundleIdentifier ?? "io.github.sfai05.Kodoku").forksync") {
        self.service = service
    }

    func readData(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw SyncError.persistenceError("Keychain read failed with OSStatus \(status)")
        }
        return result as? Data
    }

    func writeData(_ data: Data, account: String) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let attributesToUpdate: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributesToUpdate as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw SyncError.persistenceError("Keychain update failed with OSStatus \(updateStatus)")
            }
            return
        }
        guard status == errSecSuccess else {
            throw SyncError.persistenceError("Keychain write failed with OSStatus \(status)")
        }
    }

    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SyncError.persistenceError("Keychain delete failed with OSStatus \(status)")
        }
    }
}

final class InMemoryKeychainStore: SyncKeychainStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    func readData(account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[account]
    }

    func writeData(_ data: Data, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[account] = data
    }

    func delete(account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: account)
    }
}
