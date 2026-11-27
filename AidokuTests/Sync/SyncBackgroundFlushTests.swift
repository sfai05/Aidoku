//
//  SyncBackgroundFlushTests.swift
//  AidokuTests
//
//  Created by Kodoku contributors.
//

@testable import Aidoku
import Foundation
import Testing
import UIKit

@MainActor
private final class MockBackgroundTaskManager: SyncBackgroundTaskManaging {
    var hasActiveForegroundScene = false
    private var nextRawIdentifier = 100
    private(set) var begunIdentifiers: [UIBackgroundTaskIdentifier] = []
    private(set) var endedIdentifiers: [UIBackgroundTaskIdentifier] = []
    private var activeHandlers: [UIBackgroundTaskIdentifier: @MainActor @Sendable () -> Void] = [:]

    var activeTaskCount: Int {
        activeHandlers.count
    }

    func beginBackgroundTask(
        withName taskName: String?,
        expirationHandler handler: (@MainActor @Sendable () -> Void)?
    ) -> UIBackgroundTaskIdentifier {
        nextRawIdentifier += 1
        let identifier = UIBackgroundTaskIdentifier(rawValue: nextRawIdentifier)
        begunIdentifiers.append(identifier)
        activeHandlers[identifier] = handler ?? {}
        return identifier
    }

    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        endedIdentifiers.append(identifier)
        activeHandlers.removeValue(forKey: identifier)
    }

    func expire(_ identifier: UIBackgroundTaskIdentifier) {
        guard let handler = activeHandlers.removeValue(forKey: identifier) else { return }
        handler()
    }

    func waitUntilEnded(
        _ identifier: UIBackgroundTaskIdentifier,
        timeoutNanoseconds: UInt64 = 3_000_000_000
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !endedIdentifiers.contains(identifier) {
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                Issue.record("Timed out waiting for background task \(identifier.rawValue) to end.")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private actor GatedMockStorageProvider: SyncStorageProvider {
    let providerId = "gated-mock"

    private var records: [String: (metadata: SyncSnapshotMetadata, data: Data)] = [:]
    private var nextRecordCounter = 1
    private(set) var uploadCount = 0
    private var pausedUploadIndices: Set<Int>
    private var releaseWaiters: [Int: CheckedContinuation<Error?, Never>] = [:]
    private var queuedReleaseErrors: [Int: Error?] = [:]

    init(pausedUploadIndices: Set<Int> = []) {
        self.pausedUploadIndices = pausedUploadIndices
    }

    func healthCheck() async throws -> SyncHealthStatus {
        SyncHealthStatus(
            isReachable: true,
            isAuthenticated: true,
            collectionReady: true,
            message: "OK",
            serverVersion: "0.25.0"
        )
    }

    func fetchLatestMetadata() async throws -> SyncSnapshotMetadata? {
        records.values.map(\.metadata).max {
            ($0.revision, $0.createdAt) < ($1.revision, $1.createdAt)
        }
    }

    func downloadSnapshot(metadata: SyncSnapshotMetadata) async throws -> Data {
        guard let entry = records[metadata.id] else {
            throw SyncError.collectionNotFound("missing-\(metadata.id)")
        }
        return entry.data
    }

    func uploadSnapshot(_ request: SyncUploadRequest) async throws -> SyncSnapshotMetadata {
        uploadCount += 1
        let index = uploadCount

        if pausedUploadIndices.contains(index) {
            let releaseError: Error? = if let preQueued = queuedReleaseErrors.removeValue(forKey: index) {
                preQueued
            } else {
                await withCheckedContinuation { continuation in
                    releaseWaiters[index] = continuation
                }
            }
            if let releaseError {
                throw releaseError
            }
        }

        let now = Date(timeIntervalSince1970: TimeInterval(2_000 + nextRecordCounter))
        let id = "rec_\(nextRecordCounter)"
        nextRecordCounter += 1
        let meta = SyncSnapshotMetadata(
            id: id,
            revision: request.revision,
            deviceId: request.deviceId,
            deviceName: request.deviceName,
            schemaVersion: request.schemaVersion,
            checksum: request.checksum,
            fileName: request.fileName,
            sizeBytes: request.data.count,
            createdAt: now,
            updatedAt: now
        )
        records[id] = (meta, request.data)
        return meta
    }

    func listSnapshots(limit: Int) async throws -> [SyncSnapshotMetadata] {
        let sorted = records.values.map(\.metadata).sorted {
            ($0.revision, $0.createdAt) > ($1.revision, $1.createdAt)
        }
        return Array(sorted.prefix(limit))
    }

    func deleteSnapshot(id: String) async throws {
        records.removeValue(forKey: id)
    }

    func waitForUploadStart(
        index: Int,
        timeoutNanoseconds: UInt64 = 3_000_000_000
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while uploadCount < index {
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                Issue.record("Timed out waiting for upload #\(index) to start.")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func releaseUpload(index: Int, error: Error? = nil) {
        if let waiter = releaseWaiters.removeValue(forKey: index) {
            waiter.resume(returning: error)
        } else {
            queuedReleaseErrors[index] = error
        }
    }
}

private actor FlushMockSnapshotSource: SyncSnapshotSource {
    var backup: Backup

    init(backup: Backup = SyncTestFixtures.makeBackup()) {
        self.backup = backup
    }

    func captureBackup(includeSettings: Bool) async -> Backup {
        backup
    }

    func currentSettingsDigest() async -> String? {
        SyncMerger.settingsDigest(backup.settings)
    }

    func updateBackup(_ newBackup: Backup) {
        backup = newBackup
    }
}

private actor FlushMockSnapshotApplier: SyncSnapshotApplier {
    private let source: FlushMockSnapshotSource

    init(source: FlushMockSnapshotSource) {
        self.source = source
    }

    func applyMerged(_ envelope: SyncEnvelope) async throws -> Bool {
        await source.updateBackup(envelope.backup)
        return true
    }

    func replaceAll(with envelope: SyncEnvelope) async throws {
        await source.updateBackup(envelope.backup)
    }
}

@Suite(.serialized) @MainActor
struct SyncBackgroundFlushTests {
    @MainActor
    private struct Harness {
        let suiteName: String
        let tempDir: URL
        let tombstoneURL: URL
        let timeBox: SyncTestValueBox<TimeInterval>
        let config: SyncConfiguration
        let tombstoneStore: SyncTombstoneStore
        let source: FlushMockSnapshotSource
        let provider: GatedMockStorageProvider
        let taskManager: MockBackgroundTaskManager
        let engine: SyncEngine

        init(
            pausedUploadIndices: Set<Int> = [],
            debounceSeconds: TimeInterval = 60,
            settleDelayNanoseconds: UInt64 = 0,
            autoSyncOnForeground: Bool = false,
            initialManga: [BackupLibraryManga] = [SyncTestFixtures.makeLibraryManga(mangaId: "m1")]
        ) {
            let suiteName = "ForkSyncBgFlushTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            let config = SyncConfiguration(userDefaults: defaults)
            config.isEnabled = true
            config.serverURL = "https://pb.example.com"
            config.deviceName = "Test iPhone"
            config.autoSyncDebounceSeconds = debounceSeconds
            config.autoSyncOnForeground = autoSyncOnForeground

            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let tombstoneURL = tempDir.appendingPathComponent("tombstones.json")
            let timeBox = SyncTestValueBox<TimeInterval>(5_000)
            let tombstoneStore = SyncTombstoneStore(
                fileURL: tombstoneURL,
                nowProvider: { Date(timeIntervalSince1970: timeBox.get()) },
                recordingEnabledProvider: { config.isEnabled }
            )
            let keychain = InMemoryKeychainStore()
            try? keychain.writeString("user-jwt", account: SyncKeychainAccount.pocketBaseAuthToken)
            try? keychain.writeString("user-1", account: SyncKeychainAccount.pocketBaseUserId)

            let provider = GatedMockStorageProvider(pausedUploadIndices: pausedUploadIndices)
            let source = FlushMockSnapshotSource(backup: SyncTestFixtures.makeBackup(library: initialManga))
            let applier = FlushMockSnapshotApplier(source: source)
            let taskManager = MockBackgroundTaskManager()
            let engine = SyncEngine(
                configuration: config,
                keychain: keychain,
                provider: provider,
                tombstoneStore: tombstoneStore,
                logStore: SyncLogStore(fileURL: tempDir.appendingPathComponent("logs.json")),
                snapshotSource: source,
                snapshotApplier: applier,
                backgroundTaskManager: taskManager,
                backgroundSettleDelayNanoseconds: settleDelayNanoseconds,
                nowProvider: { Date(timeIntervalSince1970: 6_000) }
            )

            self.suiteName = suiteName
            self.tempDir = tempDir
            self.tombstoneURL = tombstoneURL
            self.timeBox = timeBox
            self.config = config
            self.tombstoneStore = tombstoneStore
            self.source = source
            self.provider = provider
            self.taskManager = taskManager
            self.engine = engine
        }

        func tearDown() {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
            tempDir.removeItem()
        }
    }

    @Test func foregroundToBackgroundBounceReacquiresAssertionAndRescans() async throws {
        let harness = Harness(pausedUploadIndices: [1, 2])
        defer { harness.tearDown() }

        harness.tombstoneStore.recordLibraryAddition(
            mangaId: MangaIdentifier(sourceKey: "mangadex", mangaKey: "m-bounce-1"),
            at: SyncTestFixtures.date(5_000)
        )
        harness.engine.handleSceneDidEnterBackground()
        #expect(harness.taskManager.begunIdentifiers.count == 1)
        let id1 = harness.taskManager.begunIdentifiers[0]

        try await harness.provider.waitForUploadStart(index: 1)

        // Returning to foreground ends id1 while upload #1 is still running.
        harness.engine.handleSceneWillEnterForeground()
        #expect(harness.taskManager.endedIdentifiers == [id1])
        #expect(harness.taskManager.activeTaskCount == 0)

        // Bouncing back to background while upload #1 is still in flight must acquire id2 and schedule rescan.
        await harness.source.updateBackup(
            SyncTestFixtures.makeBackup(library: [
                SyncTestFixtures.makeLibraryManga(mangaId: "m1"),
                SyncTestFixtures.makeLibraryManga(mangaId: "m-bounce-2")
            ])
        )
        harness.tombstoneStore.recordLibraryAddition(
            mangaId: MangaIdentifier(sourceKey: "mangadex", mangaKey: "m-bounce-2"),
            at: SyncTestFixtures.date(5_100)
        )
        harness.engine.handleSceneDidEnterBackground()
        #expect(harness.taskManager.begunIdentifiers.count == 2)
        let id2 = harness.taskManager.begunIdentifiers[1]
        #expect(harness.taskManager.endedIdentifiers == [id1])
        #expect(harness.taskManager.activeTaskCount == 1)

        await harness.provider.releaseUpload(index: 1)
        try await harness.provider.waitForUploadStart(index: 2)
        #expect(harness.taskManager.endedIdentifiers == [id1])

        await harness.provider.releaseUpload(index: 2)
        try await harness.taskManager.waitUntilEnded(id2)

        #expect(harness.taskManager.endedIdentifiers == [id1, id2])
        #expect(harness.taskManager.activeTaskCount == 0)
        #expect(await harness.provider.uploadCount == 2)
        #expect(harness.config.lastSyncedRevision == 2)
    }

    @Test func expirationEndsTaskImmediatelyAndOldWorkerDeferDoesNotClobberNewFlush() async throws {
        let harness = Harness(pausedUploadIndices: [1])
        defer { harness.tearDown() }

        harness.tombstoneStore.recordLibraryAddition(
            mangaId: MangaIdentifier(sourceKey: "mangadex", mangaKey: "m-expire"),
            at: SyncTestFixtures.date(5_000)
        )
        harness.engine.handleSceneDidEnterBackground()
        #expect(harness.taskManager.begunIdentifiers.count == 1)
        let id1 = harness.taskManager.begunIdentifiers[0]

        try await harness.provider.waitForUploadStart(index: 1)

        // Simulate iOS expiring id1 while upload #1 is stalled, then immediately starting a fresh flush (id2).
        harness.taskManager.expire(id1)
        #expect(harness.taskManager.endedIdentifiers == [id1])
        #expect(harness.taskManager.activeTaskCount == 0)

        harness.engine.handleSceneDidEnterBackground()
        #expect(harness.taskManager.begunIdentifiers.count == 2)
        let id2 = harness.taskManager.begunIdentifiers[1]
        #expect(harness.taskManager.activeTaskCount == 1)

        // Release upload #1 with cancellation after id2 exists; old worker defer must NOT end id2.
        await harness.provider.releaseUpload(index: 1, error: CancellationError())
        try await harness.provider.waitForUploadStart(index: 2)
        try await harness.taskManager.waitUntilEnded(id2)

        #expect(harness.taskManager.endedIdentifiers == [id1, id2])
        #expect(harness.taskManager.activeTaskCount == 0)
        #expect(await harness.provider.uploadCount == 2)
        #expect(harness.config.lastSyncedRevision == 1)
    }

    @Test func multiSceneActiveForegroundPreventsPrematureBackgroundFlush() async throws {
        let harness = Harness()
        defer { harness.tearDown() }

        let m1 = MangaIdentifier(sourceKey: "mangadex", mangaKey: "m-scene-1")
        let m2 = MangaIdentifier(sourceKey: "mangadex", mangaKey: "m-scene-2")
        harness.tombstoneStore.recordMangaDetailsUpdate(mangaId: m1, at: Date(timeIntervalSince1970: 5_000))
        let diskAfterFirst = try Data(contentsOf: harness.tombstoneURL)

        harness.timeBox.set(5_000.5)
        harness.tombstoneStore.recordMangaDetailsUpdate(mangaId: m2, at: Date(timeIntervalSince1970: 5_001))
        #expect(try Data(contentsOf: harness.tombstoneURL) == diskAfterFirst)

        // Another scene is still active in foreground -> flush to disk, do not start background upload yet.
        harness.taskManager.hasActiveForegroundScene = true
        harness.engine.handleSceneDidEnterBackground()

        #expect(try Data(contentsOf: harness.tombstoneURL) != diskAfterFirst)
        #expect(harness.taskManager.begunIdentifiers.isEmpty)
        #expect(await harness.provider.uploadCount == 0)

        // Once the last scene leaves foreground, background flush uploads the pending state.
        harness.taskManager.hasActiveForegroundScene = false
        harness.engine.handleSceneDidEnterBackground()
        #expect(harness.taskManager.begunIdentifiers.count == 1)
        let id1 = harness.taskManager.begunIdentifiers[0]
        try await harness.taskManager.waitUntilEnded(id1)

        #expect(await harness.provider.uploadCount == 1)
        #expect(harness.config.lastSyncedRevision == 1)
    }

    @Test func backgroundObservedChangeBypassesDebounceAndFlushesImmediately() async throws {
        let harness = Harness(debounceSeconds: 60)
        defer { harness.tearDown() }

        // Enter background while clean first.
        harness.engine.handleSceneDidEnterBackground()
        #expect(harness.taskManager.begunIdentifiers.count == 1)
        try await harness.taskManager.waitUntilEnded(harness.taskManager.begunIdentifiers[0])
        #expect(await harness.provider.uploadCount == 0)

        // Trigger an observed event while in background; it must flush immediately without waiting 60s.
        harness.engine.recordAllHistoryCleared()
        try await harness.provider.waitForUploadStart(index: 1)
        #expect(harness.taskManager.begunIdentifiers.count == 2)
        try await harness.taskManager.waitUntilEnded(harness.taskManager.begunIdentifiers[1])

        #expect(await harness.provider.uploadCount == 1)
        #expect(harness.config.lastSyncedRevision == 1)
    }

    @Test func applicationWillTerminateFlushesCoalescedTombstonesAndStartsUpload() async throws {
        let harness = Harness()
        defer { harness.tearDown() }

        let m1 = MangaIdentifier(sourceKey: "mangadex", mangaKey: "m-term-1")
        let m2 = MangaIdentifier(sourceKey: "mangadex", mangaKey: "m-term-2")
        harness.tombstoneStore.recordMangaDetailsUpdate(mangaId: m1, at: Date(timeIntervalSince1970: 5_000))
        let diskAfterFirst = try Data(contentsOf: harness.tombstoneURL)

        harness.timeBox.set(5_000.5)
        harness.tombstoneStore.recordMangaDetailsUpdate(mangaId: m2, at: Date(timeIntervalSince1970: 5_001))
        #expect(try Data(contentsOf: harness.tombstoneURL) == diskAfterFirst)

        harness.engine.handleApplicationWillTerminate()

        #expect(try Data(contentsOf: harness.tombstoneURL) != diskAfterFirst)
        #expect(harness.taskManager.begunIdentifiers.count == 1)
        try await harness.taskManager.waitUntilEnded(harness.taskManager.begunIdentifiers[0])
        #expect(await harness.provider.uploadCount == 1)
        #expect(harness.config.lastSyncedRevision == 1)
    }
}
