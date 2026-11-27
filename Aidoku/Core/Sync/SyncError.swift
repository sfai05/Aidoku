//
//  SyncError.swift
//  Aidoku
//

import Foundation

enum SyncError: LocalizedError, Equatable, Sendable {
    case disabled
    case notConfigured(String)
    case invalidServerURL(String)
    case notAuthenticated
    case authenticationFailed(String)
    case authenticationExpired
    case collectionNotFound(String)
    case permissionDenied(String)
    case revisionConflict(expectedRevision: Int)
    case checksumMismatch(expected: String, actual: String)
    case corruptedSnapshot(String)
    case unsupportedSchemaVersion(Int)
    case conflictRetryExhausted(attempts: Int)
    case networkError(String)
    case serverError(statusCode: Int, message: String)
    case persistenceError(String)

    var errorDescription: String? {
        switch self {
            case .disabled:
                "Sync is currently disabled."
            case let .notConfigured(detail):
                "Sync is not configured: \(detail)"
            case let .invalidServerURL(url):
                "Invalid server URL: \(url)"
            case .notAuthenticated:
                "Not signed in to the sync server."
            case let .authenticationFailed(message):
                "Authentication failed: \(message)"
            case .authenticationExpired:
                "Sync session expired. Please sign in again."
            case let .collectionNotFound(name):
                "PocketBase collection '\(name)' was not found."
            case let .permissionDenied(message):
                "Permission denied by sync server: \(message)"
            case let .revisionConflict(expectedRevision):
                "Sync revision conflict at revision \(expectedRevision)."
            case let .checksumMismatch(expected, actual):
                "Snapshot checksum mismatch (expected \(expected), got \(actual))."
            case let .corruptedSnapshot(detail):
                "Corrupted sync snapshot: \(detail)"
            case let .unsupportedSchemaVersion(version):
                "Unsupported sync snapshot schema version \(version). Please update Kodoku."
            case let .conflictRetryExhausted(attempts):
                "Sync failed after \(attempts) optimistic locking retries."
            case let .networkError(message):
                "Network error: \(message)"
            case let .serverError(statusCode, message):
                "Server error (\(statusCode)): \(message)"
            case let .persistenceError(message):
                "Local sync persistence error: \(message)"
        }
    }
}
