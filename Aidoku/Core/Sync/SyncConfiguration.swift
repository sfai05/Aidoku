//
//  SyncConfiguration.swift
//  Aidoku
//

import Foundation
import UIKit

final class SyncConfiguration: @unchecked Sendable {
    enum Key {
        static let prefix = "ForkSync."
        static let enabled = "\(prefix)enabled"
        static let providerId = "\(prefix)providerId"
        static let serverURL = "\(prefix)serverURL"
        static let collectionName = "\(prefix)collectionName"
        static let deviceId = "\(prefix)deviceId"
        static let deviceName = "\(prefix)deviceName"
        static let lastSyncedRevision = "\(prefix)lastSyncedRevision"
        static let lastSyncedRecordId = "\(prefix)lastSyncedRecordId"
        static let lastSyncedChecksum = "\(prefix)lastSyncedChecksum"
        static let lastSyncedAt = "\(prefix)lastSyncedAt"
        static let includeSettings = "\(prefix)includeSettings"
        static let maxRemoteSnapshots = "\(prefix)maxRemoteSnapshots"
        static let autoSyncOnForeground = "\(prefix)autoSyncOnForeground"
        static let autoSyncDebounceSeconds = "\(prefix)autoSyncDebounceSeconds"
        static let lastSyncedStats = "\(prefix)lastSyncedStats"
    }

    private let userDefaults: UserDefaults
    private let lock = NSLock()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var isEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return userDefaults.bool(forKey: Key.enabled)
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            userDefaults.set(newValue, forKey: Key.enabled)
        }
    }

    var providerId: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return userDefaults.string(forKey: Key.providerId) ?? "pocketbase"
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            userDefaults.set(newValue, forKey: Key.providerId)
        }
    }

    var serverURL: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return userDefaults.string(forKey: Key.serverURL)
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            if let newValue {
                let normalized = (try? Self.normalizeServerURL(newValue).absoluteString) ?? newValue
                userDefaults.set(normalized, forKey: Key.serverURL)
            } else {
                userDefaults.removeObject(forKey: Key.serverURL)
            }
        }
    }

    var collectionName: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            let value = userDefaults.string(forKey: Key.collectionName)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value! : PocketBaseSchema.defaultCollectionName
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            userDefaults.set(trimmed.isEmpty ? PocketBaseSchema.defaultCollectionName : trimmed, forKey: Key.collectionName)
        }
    }

    var deviceId: String {
        lock.lock()
        defer { lock.unlock() }
        if let existing = userDefaults.string(forKey: Key.deviceId), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString
        userDefaults.set(generated, forKey: Key.deviceId)
        return generated
    }

    var deviceName: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            if let existing = userDefaults.string(forKey: Key.deviceName), !existing.isEmpty {
                return existing
            }
            return "Kodoku Device"
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            userDefaults.set(newValue, forKey: Key.deviceName)
        }
    }

    @MainActor
    func ensureDefaultDeviceName() {
        let needsName: Bool = {
            lock.lock()
            defer { lock.unlock() }
            let existing = userDefaults.string(forKey: Key.deviceName)
            return existing?.isEmpty != false
        }()
        if needsName {
            let name = UIDevice.current.name
            deviceName = name.isEmpty ? "Kodoku Device" : name
        }
    }

    var lastSyncedRevision: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return userDefaults.integer(forKey: Key.lastSyncedRevision)
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            userDefaults.set(max(0, newValue), forKey: Key.lastSyncedRevision)
        }
    }

    var lastSyncedRecordId: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return userDefaults.string(forKey: Key.lastSyncedRecordId)
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            if let newValue {
                userDefaults.set(newValue, forKey: Key.lastSyncedRecordId)
            } else {
                userDefaults.removeObject(forKey: Key.lastSyncedRecordId)
            }
        }
    }

    var lastSyncedChecksum: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return userDefaults.string(forKey: Key.lastSyncedChecksum)
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            if let newValue {
                userDefaults.set(newValue, forKey: Key.lastSyncedChecksum)
            } else {
                userDefaults.removeObject(forKey: Key.lastSyncedChecksum)
            }
        }
    }

    var lastSyncedAt: Date? {
        get {
            lock.lock()
            defer { lock.unlock() }
            let interval = userDefaults.double(forKey: Key.lastSyncedAt)
            return interval > 0 ? Date(timeIntervalSince1970: interval) : nil
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            if let newValue {
                userDefaults.set(newValue.timeIntervalSince1970, forKey: Key.lastSyncedAt)
            } else {
                userDefaults.removeObject(forKey: Key.lastSyncedAt)
            }
        }
    }

    var includeSettings: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return userDefaults.bool(forKey: Key.includeSettings)
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            userDefaults.set(newValue, forKey: Key.includeSettings)
        }
    }

    var maxRemoteSnapshots: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            let stored = userDefaults.integer(forKey: Key.maxRemoteSnapshots)
            return stored > 0 ? min(max(stored, 2), 50) : 10
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            userDefaults.set(min(max(newValue, 2), 50), forKey: Key.maxRemoteSnapshots)
        }
    }

    var autoSyncOnForeground: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            if userDefaults.object(forKey: Key.autoSyncOnForeground) == nil {
                return true
            }
            return userDefaults.bool(forKey: Key.autoSyncOnForeground)
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            userDefaults.set(newValue, forKey: Key.autoSyncOnForeground)
        }
    }

    var autoSyncDebounceSeconds: TimeInterval {
        get {
            lock.lock()
            defer { lock.unlock() }
            let stored = userDefaults.double(forKey: Key.autoSyncDebounceSeconds)
            return stored > 0 ? min(max(stored, 2), 300) : 15
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            userDefaults.set(min(max(newValue, 2), 300), forKey: Key.autoSyncDebounceSeconds)
        }
    }

    var lastSyncedStats: SyncSnapshotStats {
        get {
            lock.lock()
            defer { lock.unlock() }
            guard
                let data = userDefaults.data(forKey: Key.lastSyncedStats),
                let decoded = try? JSONDecoder().decode(SyncSnapshotStats.self, from: data)
            else {
                return .zero
            }
            return decoded
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            if let data = try? JSONEncoder().encode(newValue) {
                userDefaults.set(data, forKey: Key.lastSyncedStats)
            }
        }
    }

    func normalizedServerURL() throws -> URL {
        guard let raw = serverURL, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SyncError.notConfigured("PocketBase server URL is missing.")
        }
        return try Self.normalizeServerURL(raw)
    }

    func resetSyncProgress() {
        lock.lock()
        defer { lock.unlock() }
        userDefaults.removeObject(forKey: Key.lastSyncedRevision)
        userDefaults.removeObject(forKey: Key.lastSyncedRecordId)
        userDefaults.removeObject(forKey: Key.lastSyncedChecksum)
        userDefaults.removeObject(forKey: Key.lastSyncedAt)
        userDefaults.removeObject(forKey: Key.lastSyncedStats)
    }

    static func normalizeServerURL(_ raw: String) throws -> URL {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard
            let components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host,
            !host.isEmpty,
            let url = components.url
        else {
            throw SyncError.invalidServerURL(raw)
        }
        return url
    }
}
