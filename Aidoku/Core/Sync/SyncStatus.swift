//
//  SyncStatus.swift
//  Aidoku
//

import Foundation

extension Notification.Name {
    static let forkSyncStateChanged = Self("ForkSync.stateChanged")
}

enum SyncIndicator: String, Codable, Sendable {
    case disabled
    case synced
    case syncing
    case pendingChanges
    case error
}

struct SyncSnapshotStats: Codable, Equatable, Sendable {
    let libraryCount: Int
    let historyCount: Int
    let categoryCount: Int
    let trackCount: Int
    let readingSessionCount: Int

    static let zero = SyncSnapshotStats(
        libraryCount: 0,
        historyCount: 0,
        categoryCount: 0,
        trackCount: 0,
        readingSessionCount: 0
    )

    static func from(backup: Backup) -> SyncSnapshotStats {
        SyncSnapshotStats(
            libraryCount: backup.library?.count ?? 0,
            historyCount: backup.history?.count ?? 0,
            categoryCount: backup.categories?.count ?? 0,
            trackCount: backup.trackItems?.count ?? 0,
            readingSessionCount: backup.readingSessions?.count ?? 0
        )
    }
}

struct SyncStatusSnapshot: Equatable, Sendable {
    let indicator: SyncIndicator
    let serverURL: String?
    let lastSyncedAt: Date?
    let lastSyncedRevision: Int
    let hasPendingChanges: Bool
    let lastErrorMessage: String?
    let stats: SyncSnapshotStats
}

enum SyncAction: String, Codable, Sendable {
    case upToDate
    case pulled
    case pushed
    case merged
    case forcePushed
    case forcePulled
}

struct SyncResult: Equatable, Sendable {
    let action: SyncAction
    let revision: Int
    let stats: SyncSnapshotStats
    let durationSeconds: TimeInterval
}

enum SyncTriggerReason: String, Sendable {
    case manual
    case foreground
    case background
    case debouncedChange
}
