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
    case trackAdded(trackerId: String, mangaId: MangaIdentifier)
    case generalChange
}

final class SyncObserverBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []
    private var applyingDepth = 0

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

        let center = NotificationCenter.default
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
            NotificationCenter.default.removeObserver(token)
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

    private var activeSyncTask: Task<SyncResult, Error>?
    private var isSyncing = false
    private var pendingFollowUpSync = false
    private var lastErrorMessage: String?
    private var lastForegroundSyncAt: Date = .distantPast
    private var debounceTask: Task<Void, Never>?

    init(
        configuration: SyncConfiguration = SyncConfiguration(),
        keychain: SyncKeychainStoreProtocol = SyncKeychainStore(),
        provider: SyncStorageProvider? = nil,
        tombstoneStore: SyncTombstoneStore = .shared,
        logStore: SyncLogStore = .shared,
        snapshotSource: SyncSnapshotSource = BackupManagerSnapshotSource(),
        snapshotApplier: SyncSnapshotApplier? = nil,
        nowProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.keychain = keychain
        self.provider = provider ?? PocketBaseSyncProvider(
            configuration: configuration,
            keychain: keychain,
            logStore: logStore
        )
        self.tombstoneStore = tombstoneStore
        self.logStore = logStore
        self.snapshotSource = snapshotSource
        self.snapshotApplier = snapshotApplier ?? SyncCoreDataApplier(tombstoneStore: tombstoneStore)
        self.nowProvider = nowProvider
    }

    // MARK: - Lifecycle

    nonisolated func start() {
        observerBridge.startObserving { [weak self] event in
            guard let self else { return }
            Task {
                await self.handleObservedEvent(event)
            }
        }
    }

    nonisolated func stopObserving() {
        observerBridge.stop()
    }

    nonisolated func handleSceneWillEnterForeground() {
        Task {
            guard configuration.isEnabled, configuration.autoSyncOnForeground else { return }
            await syncIfNeeded(reason: .foreground)
        }
    }

    nonisolated func handleSceneDidEnterBackground() {
        Task { @MainActor in
            let enabled = configuration.isEnabled
            let hasPending = tombstoneStore.snapshot().hasPendingChanges
            guard enabled, hasPending else { return }

            let lock = NSLock()
            var taskId: UIBackgroundTaskIdentifier = .invalid
            var workerTask: Task<Void, Never>?

            let endBackgroundTask: @Sendable () -> Void = {
                lock.lock()
                let currentId = taskId
                taskId = .invalid
                lock.unlock()
                guard currentId != .invalid else { return }
                Task { @MainActor in
                    UIApplication.shared.endBackgroundTask(currentId)
                }
            }

            let createdId = UIApplication.shared.beginBackgroundTask(withName: "ForkSyncBackgroundFlush") {
                workerTask?.cancel()
                endBackgroundTask()
            }
            lock.lock()
            taskId = createdId
            lock.unlock()

            workerTask = Task {
                await self.syncIfNeeded(reason: .background)
                endBackgroundTask()
            }
        }
    }

    // MARK: - Public Status & Control API

    func currentStatus() -> SyncStatusSnapshot {
        let hasPending = tombstoneStore.snapshot().hasPendingChanges
        let indicator: SyncIndicator = if !configuration.isEnabled {
            .disabled
        } else if isSyncing {
            .syncing
        } else if lastErrorMessage != nil {
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
            lastErrorMessage: lastErrorMessage,
            stats: configuration.lastSyncedStats
        )
    }

    @discardableResult
    func syncNow() async throws -> SyncResult {
        guard configuration.isEnabled else {
            throw SyncError.disabled
        }
        return try await runExclusiveSync(reason: .manual)
    }

    func syncIfNeeded(reason: SyncTriggerReason) async {
        guard configuration.isEnabled else { return }
        if reason == .foreground {
            let now = nowProvider()
            guard now.timeIntervalSince(lastForegroundSyncAt) >= Self.foregroundCooldownSeconds else {
                return
            }
            lastForegroundSyncAt = now
        }
        do {
            _ = try await runExclusiveSync(reason: reason)
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

// MARK: - Recovery Actions

extension SyncEngine {
    @discardableResult
    func forcePush() async throws -> SyncResult {
        guard configuration.isEnabled else {
            throw SyncError.disabled
        }
        if let existingTask = activeSyncTask {
            _ = try? await existingTask.value
        }

        debounceTask?.cancel()
        debounceTask = nil

        isSyncing = true
        lastErrorMessage = nil
        postStateChanged()

        let startDate = nowProvider()
        defer {
            isSyncing = false
            postStateChanged()
        }

        do {
            await configuration.ensureDefaultDeviceName()
            var attemptError: Error?

            for attempt in 1...Self.maxConflictRetries {
                let snap = tombstoneStore.snapshotWithEpoch()
                let backup = await snapshotSource.captureBackup(includeSettings: configuration.includeSettings)
                let remoteLatest = try? await provider.fetchLatestMetadata()
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

    @discardableResult
    func forcePull(recordId: String? = nil) async throws -> SyncResult {
        guard configuration.isEnabled else {
            throw SyncError.disabled
        }
        if let existingTask = activeSyncTask {
            _ = try? await existingTask.value
        }

        debounceTask?.cancel()
        debounceTask = nil

        isSyncing = true
        lastErrorMessage = nil
        postStateChanged()

        let startDate = nowProvider()
        defer {
            isSyncing = false
            postStateChanged()
        }

        do {
            let targetMeta: SyncSnapshotMetadata? = if let recordId {
                try await provider.listSnapshots(limit: 50).first { $0.id == recordId }
            } else {
                try await provider.fetchLatestMetadata()
            }

            guard let targetMeta else {
                throw SyncError.notConfigured("No matching snapshot found on sync server.")
            }

            let rawData = try await provider.downloadSnapshot(metadata: targetMeta)
            let remoteEnvelope = try SyncEnvelopeCodec.decode(rawData)

            observerBridge.beginApplyingSync()
            defer { observerBridge.endApplyingSync() }
            try await snapshotApplier.replaceAll(with: remoteEnvelope)

            tombstoneStore.replaceTombstones(remoteEnvelope.tombstones, clearPendingChanges: true)

            let now = nowProvider()
            let stats = SyncSnapshotStats.from(backup: remoteEnvelope.backup)
            configuration.lastSyncedRevision = targetMeta.revision
            configuration.lastSyncedRecordId = targetMeta.id
            configuration.lastSyncedChecksum = targetMeta.checksum
            configuration.lastSyncedAt = now
            configuration.lastSyncedStats = stats
            lastErrorMessage = nil

            let duration = nowProvider().timeIntervalSince(startDate)
            await logStore.log(
                level: .info,
                category: "recovery",
                message: "Force Pull restored revision \(targetMeta.revision)."
            )
            return SyncResult(
                action: .forcePulled,
                revision: targetMeta.revision,
                stats: stats,
                durationSeconds: max(0, duration)
            )
        } catch {
            lastErrorMessage = error.localizedDescription
            await logStore.log(level: .error, category: "recovery", message: "Force Pull failed: \(error.localizedDescription)")
            throw error
        }
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
        postStateChanged()
    }
}

// MARK: - Exclusive Sync Runner

private extension SyncEngine {
    func runExclusiveSync(reason: SyncTriggerReason) async throws -> SyncResult {
        if let activeSyncTask {
            pendingFollowUpSync = true
            return try await activeSyncTask.value
        }

        let task = Task<SyncResult, Error> {
            try await performSyncWithRetries(reason: reason)
        }
        activeSyncTask = task
        isSyncing = true
        lastErrorMessage = nil
        postStateChanged()

        do {
            var latestResult = try await task.value
            activeSyncTask = nil

            while pendingFollowUpSync {
                pendingFollowUpSync = false
                let followUpTask = Task<SyncResult, Error> {
                    try await performSyncWithRetries(reason: .debouncedChange)
                }
                activeSyncTask = followUpTask
                latestResult = try await followUpTask.value
                activeSyncTask = nil
            }

            isSyncing = false
            postStateChanged()
            return latestResult
        } catch {
            activeSyncTask = nil
            pendingFollowUpSync = false
            isSyncing = false
            lastErrorMessage = error.localizedDescription
            postStateChanged()
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
        let localSnapshot = tombstoneStore.snapshotWithEpoch()
        let localTombstones = localSnapshot.tombstones
        let hasPendingChanges = localSnapshot.hasPendingChanges
        let epoch = localSnapshot.epoch
        let remoteLatest = try await provider.fetchLatestMetadata()
        let now = nowProvider()

        if
            let remoteLatest,
            !hasPendingChanges,
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

        let localBackup = await snapshotSource.captureBackup(includeSettings: configuration.includeSettings)
        let localEnvelope = SyncEnvelope(
            revision: configuration.lastSyncedRevision,
            deviceId: configuration.deviceId,
            deviceName: configuration.deviceName,
            updatedAt: now,
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
            includeSettings: configuration.includeSettings
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

    private func handleObservedEvent(_ event: SyncObservedEvent) {
        switch event {
            case let .libraryAdded(id):
                if let id {
                    tombstoneStore.recordLibraryAddition(mangaId: id)
                } else {
                    tombstoneStore.markPendingLocalChanges()
                }
            case let .libraryRemoved(id):
                if let id {
                    tombstoneStore.recordLibraryDeletion(mangaId: id)
                } else {
                    tombstoneStore.markPendingLocalChanges()
                }
            case let .historyRead(ids):
                tombstoneStore.recordHistoryRead(chapterIds: ids)
            case let .historyChaptersRemoved(ids):
                tombstoneStore.recordHistoryDeletion(chapterIds: ids)
            case let .historyMangaRemoved(id):
                tombstoneStore.recordMangaHistoryDeletion(mangaId: id)
            case let .mangaCategoriesUpdated(ids):
                if ids.isEmpty {
                    tombstoneStore.markPendingLocalChanges()
                } else {
                    for id in ids {
                        tombstoneStore.recordMangaCategoriesUpdate(mangaId: id)
                    }
                }
            case let .trackAdded(trackerId, mangaId):
                tombstoneStore.recordTrackUpsert(trackerId: trackerId, mangaId: mangaId)
            case .generalChange:
                tombstoneStore.markPendingLocalChanges()
        }

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
