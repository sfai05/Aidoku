//
//  SyncEngine.swift
//  Aidoku
//

import Foundation
import UIKit

enum SyncObservedEvent: Sendable {
    case libraryAdded(MangaIdentifier?)
    case libraryRemoved(MangaIdentifier?)
    case historyRead([ChapterIdentifier])
    case historyChaptersRemoved([ChapterIdentifier])
    case historyMangaRemoved(MangaIdentifier)
    case mangaCategoriesUpdated([MangaIdentifier])
    case mangaDetailsUpdated(MangaIdentifier?)
    case trackAdded(trackerId: String, mangaId: MangaIdentifier)
    case generalChange
}

@MainActor
private final class BackgroundTaskBox {
    var identifier: UIBackgroundTaskIdentifier = .invalid
    var workerTask: Task<Void, Never>?

    func end() {
        let currentId = identifier
        identifier = .invalid
        guard currentId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(currentId)
    }
}

final class SyncObserverBridge: @unchecked Sendable {
    private let notificationCenter: NotificationCenter
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []
    private var applyingDepth = 0

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    deinit {
        stop()
    }

    var isApplyingSync: Bool {
        lock.lock()
        defer { lock.unlock() }
        return applyingDepth > 0
    }

    func beginApplyingSync() {
        lock.lock()
        applyingDepth += 1
        lock.unlock()
    }

    func endApplyingSync() {
        lock.lock()
        applyingDepth = max(0, applyingDepth - 1)
        lock.unlock()
    }

    func startObserving(handler: @escaping @Sendable (SyncObservedEvent) -> Void) {
        lock.lock()
        guard tokens.isEmpty else {
            lock.unlock()
            return
        }

        let center = notificationCenter
        let names: [Notification.Name] = [
            .addToLibrary,
            .removeFromLibrary,
            .historyAdded,
            .historySet,
            .historyRemoved,
            .updateMangaCategories,
            .updateCategories,
            .updateTrackers,
            .trackItemAdded,
            .updateMangaDetails,
            .updateSourceLists,
            .mangaUpdatesViewed
        ]

        tokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
                guard let self, !self.isApplyingSync else { return }
                let event = Self.extractEvent(from: notification)
                handler(event)
            }
        }
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let currentTokens = tokens
        tokens = []
        lock.unlock()
        for token in currentTokens {
            notificationCenter.removeObserver(token)
        }
    }

    private static func extractEvent(from notification: Notification) -> SyncObservedEvent {
        var event: SyncObservedEvent = .generalChange
        switch notification.name {
            case .addToLibrary:
                event = .libraryAdded(notification.object as? MangaIdentifier)
            case .removeFromLibrary:
                event = .libraryRemoved(notification.object as? MangaIdentifier)
            case .historyAdded:
                if let ids = notification.object as? [ChapterIdentifier] {
                    event = .historyRead(ids)
                }
            case .historySet:
                if let pair = notification.object as? (ChapterIdentifier, Int) {
                    event = .historyRead([pair.0])
                }
            case .historyRemoved:
                if let ids = notification.object as? [ChapterIdentifier] {
                    event = .historyChaptersRemoved(ids)
                } else if let mangaId = notification.object as? MangaIdentifier {
                    event = .historyMangaRemoved(mangaId)
                }
            case .updateMangaCategories:
                if let infos = notification.object as? [MangaInfo] {
                    event = .mangaCategoriesUpdated(infos.map(\.id))
                } else if let info = notification.object as? MangaInfo {
                    event = .mangaCategoriesUpdated([info.id])
                } else if let mangaId = notification.object as? MangaIdentifier {
                    event = .mangaCategoriesUpdated([mangaId])
                }
            case .trackItemAdded:
                if let item = notification.object as? TrackItem {
                    event = .trackAdded(trackerId: item.trackerId, mangaId: item.mangaId)
                }
            case .updateMangaDetails:
                if let manga = notification.object as? Manga {
                    event = .mangaDetailsUpdated(manga.identifier)
                } else if let mangaId = notification.object as? MangaIdentifier {
                    event = .mangaDetailsUpdated(mangaId)
                } else {
                    event = .mangaDetailsUpdated(nil)
                }
            default:
                break
        }
        return event
    }
}

actor SyncEngine {
    static let shared = SyncEngine()

    private static let maxConflictRetries = 3
    private static let foregroundCooldownSeconds: TimeInterval = 5

    let configuration: SyncConfiguration
    private let keychain: SyncKeychainStoreProtocol
    private let provider: SyncStorageProvider
    private let tombstoneStore: SyncTombstoneStore
    private let logStore: SyncLogStore
    private let snapshotSource: SyncSnapshotSource
    private let snapshotApplier: SyncSnapshotApplier
    private let nowProvider: @Sendable () -> Date
    private let observerBridge = SyncObserverBridge()

    private var isOperationActive = false
    private var pendingOperationWaiters: [CheckedContinuation<Void, Never>] = []
    private var activeCoalescedSyncTask: Task<SyncResult, Error>?
    private var currentRunningTask: Task<SyncResult, Error>?
    private var isSyncing = false
    private var pendingFollowUpSync = false
    private var lastErrorMessage: String?
    private var lastForegroundSyncAt: Date = .distantPast
    private var debounceTask: Task<Void, Never>?

    let foregroundCooldownSeconds: TimeInterval

    init(
        configuration: SyncConfiguration = SyncConfiguration(),
        keychain: SyncKeychainStoreProtocol = SyncKeychainStore(),
        provider: SyncStorageProvider? = nil,
        tombstoneStore: SyncTombstoneStore = .shared,
        logStore: SyncLogStore = .shared,
        snapshotSource: SyncSnapshotSource = BackupManagerSnapshotSource(),
        snapshotApplier: SyncSnapshotApplier? = nil,
        foregroundCooldownSeconds: TimeInterval = SyncEngine.foregroundCooldownSeconds,
        nowProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.keychain = keychain
        self.provider = provider ?? PocketBaseSyncProvider(
            configuration: configuration,
            keychain: keychain,
            logStore: logStore,
            nowProvider: nowProvider
        )
        self.tombstoneStore = tombstoneStore
        self.logStore = logStore
        self.snapshotSource = snapshotSource
        self.snapshotApplier = snapshotApplier ?? SyncCoreDataApplier(tombstoneStore: tombstoneStore)
        self.foregroundCooldownSeconds = foregroundCooldownSeconds
        self.nowProvider = nowProvider
    }

    // MARK: - Lifecycle

    nonisolated func start() {
        observerBridge.startObserving { [weak self] event in
            guard let self, self.configuration.isEnabled else { return }
            let observedAt = self.nowProvider()
            Self.recordObservedEvent(event, in: self.tombstoneStore, at: observedAt)
            Task {
                await self.scheduleObservedSync()
            }
        }
    }

    nonisolated func stopObserving() {
        observerBridge.stop()
    }

    nonisolated func recordAllHistoryCleared() {
        guard configuration.isEnabled else { return }
        tombstoneStore.recordAllHistoryCleared(at: nowProvider())
        Task {
            await self.scheduleObservedSync()
        }
    }

    nonisolated func handleSceneWillEnterForeground() {
        Task {
            guard configuration.isEnabled, configuration.autoSyncOnForeground else { return }
            await syncIfNeeded(reason: .foreground)
        }
    }

    @MainActor func handleSceneDidEnterBackground() {
        tombstoneStore.flushPendingToDisk()
        let enabled = configuration.isEnabled
        let hasPending = tombstoneStore.snapshot().hasPendingChanges
        guard enabled, hasPending else { return }

        let box = BackgroundTaskBox()
        let createdId = UIApplication.shared.beginBackgroundTask(withName: "ForkSyncBackgroundFlush") { [weak self] in
            MainActor.assumeIsolated {
                box.workerTask?.cancel()
                box.end()
            }
            Task {
                await self?.cancelActiveSync()
            }
        }
        box.identifier = createdId
        guard createdId != .invalid else { return }

        box.workerTask = Task { @MainActor [weak self] in
            if let self {
                await self.syncIfNeeded(reason: .background)
            }
            box.end()
        }
    }

    // MARK: - Public Status & Control API

    func currentStatus() -> SyncStatusSnapshot {
        let hasPending = tombstoneStore.snapshot().hasPendingChanges
        var effectiveError = lastErrorMessage
        if configuration.isEnabled, let pbProvider = provider as? PocketBaseSyncProvider {
            let trimmedServer = configuration.serverURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if effectiveError == nil {
                if trimmedServer.isEmpty {
                    effectiveError = SyncError.notConfigured("PocketBase server URL is missing.").localizedDescription
                } else if pbProvider.currentSession() == nil {
                    effectiveError = SyncError.notAuthenticated.localizedDescription
                }
            }
        }
        let indicator: SyncIndicator = if !configuration.isEnabled {
            .disabled
        } else if isSyncing {
            .syncing
        } else if effectiveError != nil {
            .error
        } else if hasPending {
            .pendingChanges
        } else {
            .synced
        }

        return SyncStatusSnapshot(
            indicator: indicator,
            serverURL: configuration.serverURL,
            lastSyncedAt: configuration.lastSyncedAt,
            lastSyncedRevision: configuration.lastSyncedRevision,
            hasPendingChanges: hasPending,
            lastErrorMessage: effectiveError,
            stats: configuration.lastSyncedStats
        )
    }

    @discardableResult
    func syncNow() async throws -> SyncResult {
        guard configuration.isEnabled else {
            throw SyncError.disabled
        }
        return try await runSerializedOperation(.regular(.manual))
    }

    func syncIfNeeded(reason: SyncTriggerReason) async {
        guard configuration.isEnabled else { return }
        if reason == .foreground {
            let now = nowProvider()
            guard now.timeIntervalSince(lastForegroundSyncAt) >= foregroundCooldownSeconds else {
                return
            }
            lastForegroundSyncAt = now
        }
        do {
            _ = try await runSerializedOperation(.regular(reason))
        } catch {
            // Errors are persisted on status & SyncLogStore for dashboard inspection.
        }
    }

    func checkHealth() async -> SyncHealthStatus {
        do {
            return try await provider.healthCheck()
        } catch {
            return SyncHealthStatus(
                isReachable: false,
                isAuthenticated: false,
                collectionReady: false,
                message: error.localizedDescription,
                serverVersion: nil
            )
        }
    }

    func listRemoteSnapshots(limit: Int = 20) async throws -> [SyncSnapshotMetadata] {
        try await provider.listSnapshots(limit: limit)
    }
}

// MARK: - Settings & Auth Facade

extension SyncEngine {
    nonisolated var pocketBaseProvider: PocketBaseSyncProvider? {
        provider as? PocketBaseSyncProvider
    }

    func setEnabled(_ enabled: Bool) {
        configuration.isEnabled = enabled
        if !enabled {
            debounceTask?.cancel()
            debounceTask = nil
            pendingFollowUpSync = false
            lastErrorMessage = nil
        }
        postStateChanged()
    }

    func notifyConfigurationChanged() {
        postStateChanged()
    }

    @discardableResult
    func signIn(serverURL: String, email: String, password: String) async throws -> PocketBaseAuthSession {
        guard let pbProvider = pocketBaseProvider else {
            throw SyncError.notConfigured("PocketBase provider is unavailable.")
        }

        await acquireExclusiveLock()
        defer {
            releaseExclusiveLock()
            postStateChanged()
        }

        let previousServerURL = configuration.serverURL
        let previousUserId = pbProvider.currentSession()?.userId
        let session = try await pbProvider.signIn(serverURL: serverURL, email: email, password: password)

        let switchedServer = previousServerURL != nil && previousServerURL != configuration.serverURL
        let switchedUser = previousUserId != nil && previousUserId != session.userId
        if switchedServer || switchedUser {
            configuration.resetSyncProgress()
            tombstoneStore.reset()
            await logStore.log(
                level: .info,
                category: "auth",
                message: "Reset sync cursor after switching PocketBase server or account."
            )
        }
        lastErrorMessage = nil
        return session
    }

    func signOut() async {
        debounceTask?.cancel()
        debounceTask = nil
        pendingFollowUpSync = false

        await acquireExclusiveLock()
        defer {
            releaseExclusiveLock()
            postStateChanged()
        }

        try? pocketBaseProvider?.signOut()
        configuration.isEnabled = false
        lastErrorMessage = nil
        await logStore.log(level: .info, category: "auth", message: "Signed out of PocketBase.")
    }

    func deleteRemoteSnapshot(id: String) async throws {
        await acquireExclusiveLock()
        defer { releaseExclusiveLock() }

        try await provider.deleteSnapshot(id: id)
        await logStore.log(level: .info, category: "cleanup", message: "Deleted remote snapshot \(id).")
    }
}

// MARK: - Recovery Actions

extension SyncEngine {
    @discardableResult
    func forcePush() async throws -> SyncResult {
        guard configuration.isEnabled else {
            throw SyncError.disabled
        }
        return try await runSerializedOperation(.forcePush)
    }

    @discardableResult
    func forcePull(recordId: String? = nil, publishAsNewRevision: Bool = true) async throws -> SyncResult {
        guard configuration.isEnabled else {
            throw SyncError.disabled
        }
        return try await runSerializedOperation(.forcePull(recordId: recordId, publishAsNewRevision: publishAsNewRevision))
    }

    @discardableResult
    func cleanupRemoteSnapshots(keepLatest: Int? = nil) async throws -> Int {
        let keepCount = max(1, keepLatest ?? configuration.maxRemoteSnapshots)
        let snapshots = try await provider.listSnapshots(limit: 100)
        let sorted = snapshots.sorted {
            if $0.revision != $1.revision {
                return $0.revision > $1.revision
            }
            return $0.createdAt > $1.createdAt
        }
        guard sorted.count > keepCount else { return 0 }

        var deleted = 0
        for stale in sorted.dropFirst(keepCount) {
            try await provider.deleteSnapshot(id: stale.id)
            deleted += 1
        }
        await logStore.log(level: .info, category: "cleanup", message: "Pruned \(deleted) stale remote snapshot(s).")
        return deleted
    }

    func resetLocalSyncState(clearCredentials: Bool = false) async {
        debounceTask?.cancel()
        debounceTask = nil
        pendingFollowUpSync = false
        await acquireExclusiveLock()
        defer {
            releaseExclusiveLock()
            if !isOperationActive {
                isSyncing = false
            }
            postStateChanged()
        }

        configuration.resetSyncProgress()
        tombstoneStore.reset()
        lastErrorMessage = nil

        if clearCredentials {
            configuration.isEnabled = false
            try? keychain.delete(account: SyncKeychainAccount.pocketBaseAuthToken)
            try? keychain.delete(account: SyncKeychainAccount.pocketBaseUserId)
            try? keychain.delete(account: SyncKeychainAccount.pocketBaseUserEmail)
        }

        await logStore.log(
            level: .warning,
            category: "recovery",
            message: clearCredentials ? "Reset local sync state and cleared credentials." : "Reset local sync cursor state."
        )
    }
}

private extension SyncEngine {
    enum SerializedOperationKind: Sendable {
        case regular(SyncTriggerReason)
        case forcePush
        case forcePull(recordId: String?, publishAsNewRevision: Bool)

        var isForceOperation: Bool {
            switch self {
                case .regular:
                    false
                case .forcePush, .forcePull:
                    true
            }
        }
    }

    func performForcePush() async throws -> SyncResult {
        let startDate = nowProvider()
        do {
            try await provider.refreshSessionIfNeeded()
            await configuration.ensureDefaultDeviceName()
            var attemptError: Error?

            for attempt in 1...Self.maxConflictRetries {
                let snap = tombstoneStore.snapshotWithEpoch()
                let backup = await snapshotSource.captureBackup(includeSettings: configuration.includeSettings)
                let remoteLatest = try await provider.fetchLatestMetadata()
                let nextRevision = max(remoteLatest?.revision ?? 0, configuration.lastSyncedRevision) + 1
                let now = nowProvider()

                let envelope = SyncEnvelope(
                    revision: nextRevision,
                    deviceId: configuration.deviceId,
                    deviceName: configuration.deviceName,
                    updatedAt: now,
                    tombstones: snap.tombstones,
                    backup: backup
                )

                do {
                    let uploaded = try await encodeAndUpload(envelope: envelope)
                    tombstoneStore.replaceTombstones(snap.tombstones, clearPendingChanges: true, expectedEpoch: snap.epoch)

                    let stats = SyncSnapshotStats.from(backup: backup)
                    configuration.lastSyncedRevision = uploaded.revision
                    configuration.lastSyncedRecordId = uploaded.id
                    configuration.lastSyncedChecksum = uploaded.checksum
                    configuration.lastSyncedSettingsDigest = configuration.includeSettings
                        ? SyncMerger.settingsDigest(backup.settings)
                        : nil
                    configuration.lastSyncedAt = now
                    configuration.lastSyncedStats = stats
                    lastErrorMessage = nil

                    await pruneRemoteSnapshotsIfNeeded()

                    let duration = nowProvider().timeIntervalSince(startDate)
                    await logStore.log(
                        level: .info,
                        category: "recovery",
                        message: "Force Push completed at revision \(uploaded.revision)."
                    )
                    return SyncResult(
                        action: .forcePushed,
                        revision: uploaded.revision,
                        stats: stats,
                        durationSeconds: max(0, duration)
                    )
                } catch SyncError.revisionConflict {
                    attemptError = SyncError.revisionConflict(expectedRevision: nextRevision)
                    await logStore.log(
                        level: .warning,
                        category: "recovery",
                        message: "Force Push revision conflict at rev \(nextRevision) (attempt \(attempt))."
                    )
                }
            }

            let exhausted = SyncError.conflictRetryExhausted(attempts: Self.maxConflictRetries)
            lastErrorMessage = (attemptError ?? exhausted).localizedDescription
            throw exhausted
        } catch {
            lastErrorMessage = error.localizedDescription
            await logStore.log(level: .error, category: "recovery", message: "Force Push failed: \(error.localizedDescription)")
            throw error
        }
    }

    func performForcePull(recordId: String?, publishAsNewRevision: Bool) async throws -> SyncResult {
        let startDate = nowProvider()
        do {
            try await provider.refreshSessionIfNeeded()
            await configuration.ensureDefaultDeviceName()

            let latestMeta = try await provider.fetchLatestMetadata()
            let targetMeta: SyncSnapshotMetadata? = if let recordId {
                if latestMeta?.id == recordId {
                    latestMeta
                } else {
                    try await provider.listSnapshots(limit: 50).first { $0.id == recordId }
                }
            } else {
                latestMeta
            }

            guard let targetMeta else {
                throw SyncError.notConfigured("No matching snapshot found on sync server.")
            }

            let rawData = try await provider.downloadSnapshot(metadata: targetMeta)
            let remoteEnvelope = try SyncEnvelopeCodec.decode(rawData)
            let preApplyEpoch = tombstoneStore.snapshotWithEpoch().epoch

            do {
                observerBridge.beginApplyingSync()
                defer { observerBridge.endApplyingSync() }
                try await snapshotApplier.replaceAll(with: remoteEnvelope)
            }

            let isRestoringOlderSnapshot = recordId != nil && latestMeta != nil && targetMeta.id != latestMeta?.id
            var finalRevision = targetMeta.revision
            var finalRecordId = targetMeta.id
            var finalChecksum = targetMeta.checksum

            if publishAsNewRevision, isRestoringOlderSnapshot {
                let published = try await publishRollbackSnapshot(
                    envelope: remoteEnvelope,
                    latestMeta: latestMeta,
                    targetMeta: targetMeta
                )
                finalRevision = published.revision
                finalRecordId = published.id
                finalChecksum = published.checksum
                await pruneRemoteSnapshotsIfNeeded()
            }

            tombstoneStore.replaceTombstones(
                remoteEnvelope.tombstones,
                clearPendingChanges: true,
                expectedEpoch: preApplyEpoch
            )

            let now = nowProvider()
            let stats = SyncSnapshotStats.from(backup: remoteEnvelope.backup)
            configuration.lastSyncedRevision = finalRevision
            configuration.lastSyncedRecordId = finalRecordId
            configuration.lastSyncedChecksum = finalChecksum
            configuration.lastSyncedSettingsDigest = configuration.includeSettings
                ? SyncMerger.settingsDigest(remoteEnvelope.backup.settings)
                : nil
            configuration.lastSyncedAt = now
            configuration.lastSyncedStats = stats
            lastErrorMessage = nil

            let duration = nowProvider().timeIntervalSince(startDate)
            await logStore.log(
                level: .info,
                category: "recovery",
                message: "Force Pull restored revision \(targetMeta.revision) (head now rev \(finalRevision))."
            )
            return SyncResult(
                action: .forcePulled,
                revision: finalRevision,
                stats: stats,
                durationSeconds: max(0, duration)
            )
        } catch {
            lastErrorMessage = error.localizedDescription
            await logStore.log(level: .error, category: "recovery", message: "Force Pull failed: \(error.localizedDescription)")
            throw error
        }
    }

    func publishRollbackSnapshot(
        envelope: SyncEnvelope,
        latestMeta: SyncSnapshotMetadata?,
        targetMeta: SyncSnapshotMetadata
    ) async throws -> SyncSnapshotMetadata {
        for attempt in 1...Self.maxConflictRetries {
            let currentLatest = (attempt == 1 ? latestMeta : try await provider.fetchLatestMetadata()) ?? targetMeta
            let nextRevision = max(currentLatest.revision, targetMeta.revision, configuration.lastSyncedRevision) + 1
            let rollbackEnvelope = SyncEnvelope(
                schemaVersion: SyncEnvelope.currentSchemaVersion,
                revision: nextRevision,
                deviceId: configuration.deviceId,
                deviceName: configuration.deviceName,
                updatedAt: nowProvider(),
                tombstones: envelope.tombstones,
                backup: envelope.backup
            )
            do {
                return try await encodeAndUpload(envelope: rollbackEnvelope)
            } catch SyncError.revisionConflict {
                await logStore.log(
                    level: .warning,
                    category: "recovery",
                    message: "Rollback publish conflict at rev \(nextRevision) (attempt \(attempt))."
                )
            }
        }
        throw SyncError.conflictRetryExhausted(attempts: Self.maxConflictRetries)
    }
}

// MARK: - Exclusive Sync Runner

private extension SyncEngine {
    func cancelActiveSync() {
        debounceTask?.cancel()
        debounceTask = nil
        pendingFollowUpSync = false
        currentRunningTask?.cancel()
    }

    func acquireExclusiveLock() async {
        if isOperationActive {
            await withCheckedContinuation { continuation in
                pendingOperationWaiters.append(continuation)
            }
        }
        isOperationActive = true
    }

    func releaseExclusiveLock() {
        if !pendingOperationWaiters.isEmpty {
            let next = pendingOperationWaiters.removeFirst()
            next.resume()
        } else {
            isOperationActive = false
        }
    }

    func executeOperation(_ kind: SerializedOperationKind) async throws -> SyncResult {
        switch kind {
            case let .regular(reason):
                try await performSyncWithRetries(reason: reason)
            case .forcePush:
                try await performForcePush()
            case let .forcePull(recordId, publishAsNewRevision):
                try await performForcePull(recordId: recordId, publishAsNewRevision: publishAsNewRevision)
        }
    }

    func runSerializedOperation(_ kind: SerializedOperationKind) async throws -> SyncResult {
        if !kind.isForceOperation, let coalesced = activeCoalescedSyncTask, pendingOperationWaiters.isEmpty {
            pendingFollowUpSync = true
            return try await coalesced.value
        }

        if kind.isForceOperation {
            debounceTask?.cancel()
            debounceTask = nil
            pendingFollowUpSync = false
        }

        await acquireExclusiveLock()
        isSyncing = true
        lastErrorMessage = nil
        postStateChanged()

        defer {
            currentRunningTask = nil
            activeCoalescedSyncTask = nil
            releaseExclusiveLock()
            if !isOperationActive {
                isSyncing = false
            }
            postStateChanged()
        }

        let task = Task<SyncResult, Error> {
            try await self.executeOperation(kind)
        }
        currentRunningTask = task
        if !kind.isForceOperation {
            activeCoalescedSyncTask = task
        }

        do {
            var latestResult = try await task.value

            if !kind.isForceOperation {
                while pendingFollowUpSync, pendingOperationWaiters.isEmpty {
                    pendingFollowUpSync = false
                    let followUpTask = Task<SyncResult, Error> {
                        try await self.executeOperation(.regular(.debouncedChange))
                    }
                    currentRunningTask = followUpTask
                    activeCoalescedSyncTask = followUpTask
                    latestResult = try await followUpTask.value
                }
            } else if pendingFollowUpSync, pendingOperationWaiters.isEmpty {
                pendingFollowUpSync = false
                scheduleDebouncedSync()
            }

            return latestResult
        } catch {
            pendingFollowUpSync = false
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    private func performSyncWithRetries(reason: SyncTriggerReason) async throws -> SyncResult {
        let startDate = nowProvider()
        await configuration.ensureDefaultDeviceName()

        var didApplyLocally = false
        var lastConflictRevision = 0
        for attempt in 1...Self.maxConflictRetries {
            do {
                return try await executeSingleSyncPass(
                    reason: reason,
                    startDate: startDate,
                    didApplyLocally: &didApplyLocally
                )
            } catch let SyncError.revisionConflict(expectedRevision) {
                lastConflictRevision = expectedRevision
                await logStore.log(
                    level: .warning,
                    category: "sync",
                    message: "Optimistic locking conflict at revision \(expectedRevision) (attempt \(attempt)/\(Self.maxConflictRetries))."
                )
            } catch {
                await logStore.log(
                    level: .error,
                    category: "sync",
                    message: "Sync (\(reason.rawValue)) failed: \(error.localizedDescription)"
                )
                throw error
            }
        }

        let error = SyncError.conflictRetryExhausted(attempts: Self.maxConflictRetries)
        await logStore.log(
            level: .error,
            category: "sync",
            message: "Exhausted conflict retries around revision \(lastConflictRevision)."
        )
        throw error
    }

    private func executeSingleSyncPass(
        reason: SyncTriggerReason,
        startDate: Date,
        didApplyLocally: inout Bool
    ) async throws -> SyncResult {
        try await provider.refreshSessionIfNeeded()

        let localSnapshot = tombstoneStore.snapshotWithEpoch()
        let localTombstones = localSnapshot.tombstones
        let hasPendingChanges = localSnapshot.hasPendingChanges
        let epoch = localSnapshot.epoch

        let localSettingsDigest = configuration.includeSettings ? await snapshotSource.currentSettingsDigest() : nil
        let localSettingsNeedSync = configuration.includeSettings
            && localSettingsDigest != configuration.lastSyncedSettingsDigest
        let localSettingsModified = configuration.includeSettings
            && configuration.lastSyncedSettingsDigest != nil
            && localSettingsDigest != configuration.lastSyncedSettingsDigest

        let remoteLatest = try await provider.fetchLatestMetadata()
        let now = nowProvider()

        if
            let remoteLatest,
            !hasPendingChanges,
            !localSettingsNeedSync,
            remoteLatest.revision == configuration.lastSyncedRevision,
            !remoteLatest.checksum.isEmpty,
            remoteLatest.checksum == configuration.lastSyncedChecksum
        {
            configuration.lastSyncedAt = now
            lastErrorMessage = nil
            let duration = max(0, nowProvider().timeIntervalSince(startDate))
            return SyncResult(
                action: .upToDate,
                revision: remoteLatest.revision,
                stats: configuration.lastSyncedStats,
                durationSeconds: duration
            )
        }

        let localUpdatedAt: Date = if hasPendingChanges || localSettingsModified {
            localSnapshot.lastMutationAt ?? now
        } else {
            configuration.lastSyncedAt ?? .distantPast
        }

        let localBackup = await snapshotSource.captureBackup(includeSettings: configuration.includeSettings)
        let localEnvelope = SyncEnvelope(
            revision: configuration.lastSyncedRevision,
            deviceId: configuration.deviceId,
            deviceName: configuration.deviceName,
            updatedAt: localUpdatedAt,
            tombstones: localTombstones,
            backup: localBackup
        )

        guard let remoteLatest else {
            let initialEnvelope = SyncEnvelope(
                revision: max(1, configuration.lastSyncedRevision + 1),
                deviceId: configuration.deviceId,
                deviceName: configuration.deviceName,
                updatedAt: now,
                tombstones: localTombstones,
                backup: localBackup
            )
            let uploaded = try await encodeAndUpload(envelope: initialEnvelope)
            tombstoneStore.replaceTombstones(localTombstones, clearPendingChanges: true, expectedEpoch: epoch)

            let stats = SyncSnapshotStats.from(backup: localBackup)
            configuration.lastSyncedRevision = uploaded.revision
            configuration.lastSyncedRecordId = uploaded.id
            configuration.lastSyncedChecksum = uploaded.checksum
            configuration.lastSyncedSettingsDigest = configuration.includeSettings
                ? SyncMerger.settingsDigest(localBackup.settings)
                : nil
            configuration.lastSyncedAt = now
            configuration.lastSyncedStats = stats
            lastErrorMessage = nil

            await logStore.log(
                level: .info,
                category: "sync",
                message: "Initial snapshot pushed (\(reason.rawValue)) at revision \(uploaded.revision)."
            )
            return SyncResult(
                action: .pushed,
                revision: uploaded.revision,
                stats: stats,
                durationSeconds: max(0, nowProvider().timeIntervalSince(startDate))
            )
        }

        let remoteData = try await provider.downloadSnapshot(metadata: remoteLatest)
        let remoteEnvelope = try SyncEnvelopeCodec.decode(remoteData)

        let mergeResult = SyncMerger.merge(
            local: localEnvelope,
            remote: remoteEnvelope,
            deviceId: configuration.deviceId,
            deviceName: configuration.deviceName,
            now: now,
            includeSettings: configuration.includeSettings,
            localSettingsModified: configuration.includeSettings ? localSettingsModified : nil
        )

        if mergeResult.localNeedsApply {
            observerBridge.beginApplyingSync()
            defer { observerBridge.endApplyingSync() }
            _ = try await snapshotApplier.applyMerged(mergeResult.mergedEnvelope)
            didApplyLocally = true
        }

        let finalRevision: Int
        let finalAction: SyncAction
        let finalChecksum: String
        let finalRecordId: String

        if mergeResult.remoteNeedsUpload {
            let nextRevision = max(remoteLatest.revision, configuration.lastSyncedRevision) + 1
            let uploadEnvelope = SyncEnvelope(
                schemaVersion: SyncEnvelope.currentSchemaVersion,
                revision: nextRevision,
                deviceId: configuration.deviceId,
                deviceName: configuration.deviceName,
                updatedAt: now,
                tombstones: mergeResult.mergedEnvelope.tombstones,
                backup: mergeResult.mergedEnvelope.backup
            )
            let uploaded = try await encodeAndUpload(envelope: uploadEnvelope)
            finalRevision = uploaded.revision
            finalChecksum = uploaded.checksum
            finalRecordId = uploaded.id
            finalAction = (mergeResult.localNeedsApply || didApplyLocally) ? .merged : .pushed
            await pruneRemoteSnapshotsIfNeeded()
        } else {
            finalRevision = remoteLatest.revision
            finalChecksum = remoteLatest.checksum
            finalRecordId = remoteLatest.id
            finalAction = (mergeResult.localNeedsApply || didApplyLocally) ? .pulled : .upToDate
        }

        tombstoneStore.replaceTombstones(
            mergeResult.mergedEnvelope.tombstones,
            clearPendingChanges: true,
            expectedEpoch: epoch
        )

        configuration.lastSyncedRevision = finalRevision
        configuration.lastSyncedRecordId = finalRecordId
        configuration.lastSyncedChecksum = finalChecksum
        configuration.lastSyncedSettingsDigest = configuration.includeSettings
            ? SyncMerger.settingsDigest(mergeResult.mergedEnvelope.backup.settings)
            : nil
        configuration.lastSyncedAt = now
        configuration.lastSyncedStats = mergeResult.stats
        lastErrorMessage = nil

        let duration = max(0, nowProvider().timeIntervalSince(startDate))
        if finalAction != .upToDate {
            await logStore.log(
                level: .info,
                category: "sync",
                message: "Sync (\(reason.rawValue)) finished: \(finalAction.rawValue) rev \(finalRevision)."
            )
        }
        return SyncResult(
            action: finalAction,
            revision: finalRevision,
            stats: mergeResult.stats,
            durationSeconds: duration
        )
    }

    private func encodeAndUpload(envelope: SyncEnvelope) async throws -> SyncSnapshotMetadata {
        let compressedData = try SyncEnvelopeCodec.encode(envelope, compress: true)
        let checksum = SyncEnvelopeCodec.sha256Hex(compressedData)
        let request = SyncUploadRequest(
            revision: envelope.revision,
            deviceId: envelope.deviceId,
            deviceName: envelope.deviceName,
            schemaVersion: envelope.schemaVersion,
            checksum: checksum,
            fileName: "snapshot_r\(envelope.revision).aidoku.gz",
            data: compressedData
        )
        return try await provider.uploadSnapshot(request)
    }

    private func pruneRemoteSnapshotsIfNeeded() async {
        do {
            _ = try await cleanupRemoteSnapshots(keepLatest: configuration.maxRemoteSnapshots)
        } catch {
            await logStore.log(
                level: .warning,
                category: "cleanup",
                message: "Deferred remote snapshot pruning failed: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Change Observation & Debounce

    private nonisolated static func recordObservedEvent(
        _ event: SyncObservedEvent,
        in tombstoneStore: SyncTombstoneStore,
        at observedAt: Date
    ) {
        switch event {
            case let .libraryAdded(id):
                if let id {
                    tombstoneStore.recordLibraryAddition(mangaId: id, at: observedAt)
                } else {
                    tombstoneStore.markPendingLocalChanges(at: observedAt)
                }
            case let .libraryRemoved(id):
                if let id {
                    tombstoneStore.recordLibraryDeletion(mangaId: id, at: observedAt)
                } else {
                    tombstoneStore.markPendingLocalChanges(at: observedAt)
                }
            case let .historyRead(ids):
                tombstoneStore.recordHistoryRead(chapterIds: ids, at: observedAt)
            case let .historyChaptersRemoved(ids):
                tombstoneStore.recordHistoryDeletion(chapterIds: ids, at: observedAt)
            case let .historyMangaRemoved(id):
                tombstoneStore.recordMangaHistoryDeletion(mangaId: id, at: observedAt)
            case let .mangaCategoriesUpdated(ids):
                if ids.isEmpty {
                    tombstoneStore.markPendingLocalChanges(at: observedAt)
                } else {
                    for id in ids {
                        tombstoneStore.recordMangaCategoriesUpdate(mangaId: id, at: observedAt)
                    }
                }
            case let .mangaDetailsUpdated(id):
                if let id {
                    tombstoneStore.recordMangaDetailsUpdate(mangaId: id, at: observedAt)
                } else {
                    tombstoneStore.markPendingLocalChanges(at: observedAt)
                }
            case let .trackAdded(trackerId, mangaId):
                tombstoneStore.recordTrackUpsert(trackerId: trackerId, mangaId: mangaId, at: observedAt)
            case .generalChange:
                tombstoneStore.markPendingLocalChanges(at: observedAt)
        }
    }

    private func scheduleObservedSync() {
        guard configuration.isEnabled else { return }
        postStateChanged()
        scheduleDebouncedSync()
    }

    private func scheduleDebouncedSync() {
        debounceTask?.cancel()
        let delaySeconds = configuration.autoSyncDebounceSeconds
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.syncIfNeeded(reason: .debouncedChange)
        }
    }

    private func postStateChanged() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .forkSyncStateChanged, object: nil)
        }
    }
}
