//
//  SyncEngineTests.swift
//  AidokuTests
//

@testable import Aidoku
import Foundation
import Testing

private actor MockStorageProvider: SyncStorageProvider {
    let providerId = "mock"

    private var records: [String: (metadata: SyncSnapshotMetadata, data: Data)] = [:]
    private var nextRecordCounter = 1
    private var concurrentConflictSnapshots: [Int: SyncEnvelope]
    private let operationDelayNanoseconds: UInt64
    private var inFlightOperations = 0
    private(set) var maxConcurrentOperations = 0
    private(set) var downloadCount = 0
    private(set) var uploadCount = 0

    init(
        initialSnapshots: [(SyncSnapshotMetadata, Data)] = [],
        concurrentConflictSnapshots: [Int: SyncEnvelope] = [:],
        operationDelayNanoseconds: UInt64 = 0
    ) {
        for (meta, data) in initialSnapshots {
            self.records[meta.id] = (meta, data)
        }
        self.concurrentConflictSnapshots = concurrentConflictSnapshots
        self.operationDelayNanoseconds = operationDelayNanoseconds
    }

    private func trackOperationStart() async {
        inFlightOperations += 1
        maxConcurrentOperations = max(maxConcurrentOperations, inFlightOperations)
        if operationDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: operationDelayNanoseconds)
        }
    }

    private func trackOperationEnd() {
        inFlightOperations = max(0, inFlightOperations - 1)
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
        await trackOperationStart()
        defer { trackOperationEnd() }
        downloadCount += 1
        guard let entry = records[metadata.id] else {
            throw SyncError.collectionNotFound("missing-record-\(metadata.id)")
        }
        return entry.data
    }

    func uploadSnapshot(_ request: SyncUploadRequest) async throws -> SyncSnapshotMetadata {
        await trackOperationStart()
        defer { trackOperationEnd() }
        uploadCount += 1
        if let concurrent = concurrentConflictSnapshots.removeValue(forKey: request.revision) {
            _ = try seedSnapshot(revision: request.revision, envelope: concurrent)
            throw SyncError.revisionConflict(expectedRevision: request.revision)
        }
        if records.values.contains(where: { $0.metadata.revision == request.revision }) {
            throw SyncError.revisionConflict(expectedRevision: request.revision)
        }

        let now = Date(timeIntervalSince1970: TimeInterval(1_000 + nextRecordCounter))
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

    func seedSnapshot(revision: Int, envelope: SyncEnvelope) throws -> SyncSnapshotMetadata {
        let data = try SyncEnvelopeCodec.encode(envelope, compress: true)
        let checksum = SyncEnvelopeCodec.sha256Hex(data)
        let id = "seeded_\(revision)"
        let meta = SyncSnapshotMetadata(
            id: id,
            revision: revision,
            deviceId: envelope.deviceId,
            deviceName: envelope.deviceName,
            schemaVersion: envelope.schemaVersion,
            checksum: checksum,
            fileName: "snapshot_r\(revision).aidoku.gz",
            sizeBytes: data.count,
            createdAt: envelope.updatedAt,
            updatedAt: envelope.updatedAt
        )
        records[id] = (meta, data)
        return meta
    }
}

private actor MockSnapshotSource: SyncSnapshotSource {
    var backup: Backup

    init(backup: Backup) {
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

private actor MockSnapshotApplier: SyncSnapshotApplier {
    private(set) var appliedMergedEnvelopes: [SyncEnvelope] = []
    private(set) var replacedEnvelopes: [SyncEnvelope] = []
    private let source: MockSnapshotSource

    init(source: MockSnapshotSource) {
        self.source = source
    }

    func applyMerged(_ envelope: SyncEnvelope) async throws -> Bool {
        appliedMergedEnvelopes.append(envelope)
        await source.updateBackup(envelope.backup)
        return true
    }

    func replaceAll(with envelope: SyncEnvelope) async throws {
        replacedEnvelopes.append(envelope)
        await source.updateBackup(envelope.backup)
    }
}

@Suite struct SyncEngineTests {
    private struct Harness {
        let suiteName: String
        let tempDir: URL
        let config: SyncConfiguration
        let keychain: InMemoryKeychainStore
        let tombstoneStore: SyncTombstoneStore
        let logStore: SyncLogStore
        let source: MockSnapshotSource
        let applier: MockSnapshotApplier
        let provider: MockStorageProvider
        let engine: SyncEngine

        init(
            localBackup: Backup = SyncTestFixtures.makeBackup(),
            concurrentConflictSnapshots: [Int: SyncEnvelope] = [:],
            maxRemoteSnapshots: Int = 10,
            operationDelayNanoseconds: UInt64 = 0,
            foregroundCooldownSeconds: TimeInterval = 5,
            nowProvider: @escaping @Sendable () -> Date = { SyncTestFixtures.date(6_000) }
        ) {
            let suiteName = "ForkSyncEngineTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            let config = SyncConfiguration(userDefaults: defaults)
            config.isEnabled = true
            config.serverURL = "https://pb.example.com"
            config.deviceName = "Test iPhone"
            config.maxRemoteSnapshots = maxRemoteSnapshots

            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let tombstoneStore = SyncTombstoneStore(
                fileURL: tempDir.appendingPathComponent("tombstones.json"),
                nowProvider: { SyncTestFixtures.date(5_000) },
                recordingEnabledProvider: { config.isEnabled }
            )
            let logStore = SyncLogStore(fileURL: tempDir.appendingPathComponent("logs.json"))
            let source = MockSnapshotSource(backup: localBackup)
            let applier = MockSnapshotApplier(source: source)
            let provider = MockStorageProvider(
                concurrentConflictSnapshots: concurrentConflictSnapshots,
                operationDelayNanoseconds: operationDelayNanoseconds
            )
            let keychain = InMemoryKeychainStore()
            try? keychain.writeString("user-jwt", account: SyncKeychainAccount.pocketBaseAuthToken)
            try? keychain.writeString("user-1", account: SyncKeychainAccount.pocketBaseUserId)

            let engine = SyncEngine(
                configuration: config,
                keychain: keychain,
                provider: provider,
                tombstoneStore: tombstoneStore,
                logStore: logStore,
                snapshotSource: source,
                snapshotApplier: applier,
                foregroundCooldownSeconds: foregroundCooldownSeconds,
                nowProvider: nowProvider
            )

            self.suiteName = suiteName
            self.tempDir = tempDir
            self.config = config
            self.keychain = keychain
            self.tombstoneStore = tombstoneStore
            self.logStore = logStore
            self.source = source
            self.applier = applier
            self.provider = provider
            self.engine = engine
        }

        func tearDown() {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            tempDir.removeItem()
        }
    }

    @Test func initialSyncPushesRevisionOneAndSecondSyncIsFastPathUpToDate() async throws {
        let localBackup = SyncTestFixtures.makeBackup(
            library: [SyncTestFixtures.makeLibraryManga(mangaId: "m1")],
            manga: [SyncTestFixtures.makeManga(id: "m1")]
        )
        let harness = Harness(localBackup: localBackup)
        defer { harness.tearDown() }

        let firstResult = try await harness.engine.syncNow()
        #expect(firstResult.action == .pushed)
        #expect(firstResult.revision == 1)
        #expect(firstResult.stats.libraryCount == 1)
        #expect(harness.config.lastSyncedRevision == 1)

        // Second sync with matching checksum and no pending changes skips snapshot download.
        let secondResult = try await harness.engine.syncNow()
        #expect(secondResult.action == .upToDate)
        #expect(secondResult.revision == 1)
        #expect(await harness.provider.downloadCount == 0)
        #expect(await harness.provider.uploadCount == 1)
    }

    @Test func bidirectionalSyncMergesAndRetriesRevisionConflict() async throws {
        let localBackup = SyncTestFixtures.makeBackup(
            library: [SyncTestFixtures.makeLibraryManga(mangaId: "m-local")],
            manga: [SyncTestFixtures.makeManga(id: "m-local")]
        )
        let concurrentRev3Envelope = SyncEnvelope(
            revision: 3,
            deviceId: "ipad-2",
            deviceName: "Other iPad",
            updatedAt: SyncTestFixtures.date(4_500),
            backup: SyncTestFixtures.makeBackup(
                library: [
                    SyncTestFixtures.makeLibraryManga(mangaId: "m-remote"),
                    SyncTestFixtures.makeLibraryManga(mangaId: "m-concurrent")
                ],
                manga: [
                    SyncTestFixtures.makeManga(id: "m-remote"),
                    SyncTestFixtures.makeManga(id: "m-concurrent")
                ]
            )
        )
        // Revision 3 conflicts once to simulate a concurrent write from another device.
        let harness = Harness(
            localBackup: localBackup,
            concurrentConflictSnapshots: [3: concurrentRev3Envelope]
        )
        defer { harness.tearDown() }

        let remoteEnvelope = SyncEnvelope(
            revision: 2,
            deviceId: "ipad-1",
            deviceName: "iPad",
            updatedAt: SyncTestFixtures.date(4_000),
            backup: SyncTestFixtures.makeBackup(
                library: [SyncTestFixtures.makeLibraryManga(mangaId: "m-remote")],
                manga: [SyncTestFixtures.makeManga(id: "m-remote")]
            )
        )
        _ = try await harness.provider.seedSnapshot(revision: 2, envelope: remoteEnvelope)

        let result = try await harness.engine.syncNow()
        #expect(result.action == .merged)
        #expect(result.revision == 4)
        #expect(result.stats.libraryCount == 3)
        #expect(await harness.applier.appliedMergedEnvelopes.count >= 1)
        #expect(harness.config.lastSyncedRevision == 4)
        #expect(await harness.provider.uploadCount == 2)
    }

    @Test func forcePushForcePullAndResetPreserveServerConfiguration() async throws {
        let localBackup = SyncTestFixtures.makeBackup(
            library: [SyncTestFixtures.makeLibraryManga(mangaId: "m-local")],
            manga: [SyncTestFixtures.makeManga(id: "m-local")]
        )
        let harness = Harness(localBackup: localBackup, maxRemoteSnapshots: 2)
        defer { harness.tearDown() }

        // Push 4 snapshots via forcePush to verify pruning keeps 2 newest.
        for _ in 0..<4 {
            _ = try await harness.engine.forcePush()
        }
        let snapshotsAfterPrune = try await harness.engine.listRemoteSnapshots()
        #expect(snapshotsAfterPrune.count == 2)

        // Seed revision 10 remotely and Force Pull.
        let remoteBackup = SyncTestFixtures.makeBackup(
            library: [SyncTestFixtures.makeLibraryManga(mangaId: "m-remote-only")],
            manga: [SyncTestFixtures.makeManga(id: "m-remote-only", title: "Remote Authoritative")]
        )
        let seededMeta = try await harness.provider.seedSnapshot(
            revision: 10,
            envelope: SyncEnvelope(
                revision: 10,
                deviceId: "ipad",
                deviceName: "iPad",
                updatedAt: SyncTestFixtures.date(5_500),
                backup: remoteBackup
            )
        )

        let pullResult = try await harness.engine.forcePull(recordId: seededMeta.id)
        #expect(pullResult.action == .forcePulled)
        #expect(pullResult.revision == 10)
        #expect(await harness.applier.replacedEnvelopes.count == 1)
        #expect(harness.config.serverURL == "https://pb.example.com")
        #expect(harness.config.lastSyncedRevision == 10)

        await harness.engine.resetLocalSyncState(clearCredentials: true)
        let status = await harness.engine.currentStatus()
        #expect(status.indicator == .disabled)
        #expect(status.lastSyncedRevision == 0)
        #expect(try harness.keychain.readString(account: SyncKeychainAccount.pocketBaseAuthToken) == nil)
    }

    @Test func syncLogStoreRedactsTokensAndPasswords() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { dir.removeItem() }
        let store = SyncLogStore(fileURL: dir.appendingPathComponent("logs.json"))

        await store.log(
            level: .error,
            category: "auth",
            message: "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpZCI6InUxIn0.signature "
                + "https://pb.example.com/file?token=secret123 {\"password\":\"mySecretPass\"}"
        )

        let entries = await store.entries()
        #expect(entries.count == 1)
        let text = await store.exportText()
        #expect(!text.contains("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"))
        #expect(!text.contains("secret123"))
        #expect(!text.contains("mySecretPass"))
        #expect(text.contains("<REDACTED"))
    }
}

@Suite struct SyncEngineConcurrencyAndTombstoneTests {
    @Test func forcePushAndForcePullAreMutuallyExclusiveWithRegularSync() async throws {
        let suiteName = "ForkSyncEngineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let config = SyncConfiguration(userDefaults: defaults)
        config.isEnabled = true
        config.serverURL = "https://pb.example.com"
        config.deviceName = "Test iPhone"

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { dir.removeItem() }
        let tombstoneStore = SyncTombstoneStore(
            fileURL: dir.appendingPathComponent("tombstones.json"),
            nowProvider: { SyncTestFixtures.date(5_000) },
            recordingEnabledProvider: { config.isEnabled }
        )
        let logStore = SyncLogStore(fileURL: dir.appendingPathComponent("logs.json"))
        let source = MockSnapshotSource(backup: SyncTestFixtures.makeBackup(manga: [SyncTestFixtures.makeManga(id: "m1")]))
        let applier = MockSnapshotApplier(source: source)
        let provider = MockStorageProvider(operationDelayNanoseconds: 35_000_000)
        let keychain = InMemoryKeychainStore()
        try keychain.writeString("user-jwt", account: SyncKeychainAccount.pocketBaseAuthToken)
        try keychain.writeString("user-1", account: SyncKeychainAccount.pocketBaseUserId)
        _ = try await provider.seedSnapshot(
            revision: 1,
            envelope: SyncEnvelope(
                revision: 1,
                deviceId: "ipad",
                deviceName: "iPad",
                updatedAt: SyncTestFixtures.date(4_000),
                backup: SyncTestFixtures.makeBackup(manga: [SyncTestFixtures.makeManga(id: "m1")])
            )
        )

        let engine = SyncEngine(
            configuration: config,
            keychain: keychain,
            provider: provider,
            tombstoneStore: tombstoneStore,
            logStore: logStore,
            snapshotSource: source,
            snapshotApplier: applier,
            nowProvider: { SyncTestFixtures.date(6_000) }
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = try await engine.syncNow() }
            group.addTask { _ = try await engine.forcePush() }
            group.addTask { _ = try await engine.forcePull() }
            try await group.waitForAll()
        }

        #expect(await provider.maxConcurrentOperations == 1)
        let finalStatus = await engine.currentStatus()
        #expect(finalStatus.indicator != .syncing)
    }

    @Test func forcePullOfOlderSnapshotPublishesNewRevisionAndSticks() async throws {
        let suiteName = "ForkSyncEngineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let config = SyncConfiguration(userDefaults: defaults)
        config.isEnabled = true
        config.serverURL = "https://pb.example.com"
        config.deviceName = "Test iPhone"

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { dir.removeItem() }
        let tombstoneStore = SyncTombstoneStore(
            fileURL: dir.appendingPathComponent("tombstones.json"),
            nowProvider: { SyncTestFixtures.date(5_000) },
            recordingEnabledProvider: { config.isEnabled }
        )
        let logStore = SyncLogStore(fileURL: dir.appendingPathComponent("logs.json"))
        let source = MockSnapshotSource(backup: SyncTestFixtures.makeBackup())
        let applier = MockSnapshotApplier(source: source)
        let provider = MockStorageProvider()
        let keychain = InMemoryKeychainStore()
        try keychain.writeString("user-jwt", account: SyncKeychainAccount.pocketBaseAuthToken)
        try keychain.writeString("user-1", account: SyncKeychainAccount.pocketBaseUserId)

        let olderRev5Meta = try await provider.seedSnapshot(
            revision: 5,
            envelope: SyncEnvelope(
                revision: 5,
                deviceId: "ipad",
                deviceName: "iPad",
                updatedAt: SyncTestFixtures.date(3_000),
                backup: SyncTestFixtures.makeBackup(
                    library: [SyncTestFixtures.makeLibraryManga(mangaId: "m-older")],
                    manga: [SyncTestFixtures.makeManga(id: "m-older", title: "Wanted Rollback")]
                )
            )
        )
        _ = try await provider.seedSnapshot(
            revision: 10,
            envelope: SyncEnvelope(
                revision: 10,
                deviceId: "iphone",
                deviceName: "iPhone",
                updatedAt: SyncTestFixtures.date(5_000),
                backup: SyncTestFixtures.makeBackup(
                    library: [SyncTestFixtures.makeLibraryManga(mangaId: "m-bad")],
                    manga: [SyncTestFixtures.makeManga(id: "m-bad", title: "Accidental Edit")]
                )
            )
        )

        let engine = SyncEngine(
            configuration: config,
            keychain: keychain,
            provider: provider,
            tombstoneStore: tombstoneStore,
            logStore: logStore,
            snapshotSource: source,
            snapshotApplier: applier,
            nowProvider: { SyncTestFixtures.date(6_000) }
        )

        let rollbackResult = try await engine.forcePull(recordId: olderRev5Meta.id)
        #expect(rollbackResult.action == .forcePulled)
        #expect(rollbackResult.revision == 11)
        #expect(config.lastSyncedRevision == 11)

        // Subsequent sync remains up-to-date and does NOT re-merge the overwritten rev 10 data.
        let nextSync = try await engine.syncNow()
        #expect(nextSync.action == .upToDate)
        #expect(nextSync.revision == 11)
        let currentMangaIds = await source.backup.manga?.map(\.id) ?? []
        #expect(currentMangaIds == ["m-older"])
    }

    @Test func tombstoneStoreGatesOnEnabledSuspendsAndPreservesConcurrentEpochMutations() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { dir.removeItem() }
        let fileURL = dir.appendingPathComponent("tombstones.json")

        let isEnabledBox = SyncTestValueBox(false)
        let nowTimeBox = SyncTestValueBox(TimeInterval(10_000_000))

        let store = SyncTombstoneStore(
            fileURL: fileURL,
            nowProvider: { Date(timeIntervalSince1970: nowTimeBox.get()) },
            recordingEnabledProvider: { isEnabledBox.get() }
        )

        let m1 = MangaIdentifier(sourceKey: "mangadex", mangaKey: "m1")
        let m2 = MangaIdentifier(sourceKey: "mangadex", mangaKey: "m2")

        // When sync is disabled, mutations are ignored and nothing is persisted.
        store.recordLibraryDeletion(mangaId: m1)
        store.recordHistoryRead(chapterIds: [ChapterIdentifier(sourceKey: "mangadex", mangaKey: "m1", chapterKey: "c1")])
        #expect(!store.snapshot().hasPendingChanges)
        #expect(!fileURL.exists)

        // Enable recording and verify suspension ignores writes while enabled.
        isEnabledBox.set(true)

        store.withRecordingSuspended {
            store.recordLibraryDeletion(mangaId: m1)
        }
        #expect(!store.snapshot().hasPendingChanges)

        // Old >90-day tombstones are pruned automatically when persisted.
        store.recordLibraryDeletion(mangaId: m1, at: Date(timeIntervalSince1970: 1_000))
        #expect(store.snapshot().tombstones.libraryManga.isEmpty)

        // Concurrent mutation advancing epoch preserves both pending flag and concurrent tombstone.
        store.recordLibraryDeletion(mangaId: m1)
        let initialEpochSnapshot = store.snapshotWithEpoch()
        store.recordLibraryDeletion(mangaId: m2)
        store.replaceTombstones(.empty, clearPendingChanges: true, expectedEpoch: initialEpochSnapshot.epoch)

        let afterReplace = store.snapshotWithEpoch()
        #expect(afterReplace.hasPendingChanges)
        #expect(afterReplace.tombstones.libraryManga.map(\.mangaId) == ["m1", "m2"])

        // When epoch matches without concurrent edits, pending changes clear as expected.
        store.replaceTombstones(.empty, clearPendingChanges: true, expectedEpoch: afterReplace.epoch)
        #expect(!store.snapshot().hasPendingChanges)
        #expect(store.snapshot().tombstones.libraryManga.isEmpty)

        nowTimeBox.mutate { $0 += 1 }
    }

    @Test func observerBridgeSuppressesEchoNotificationsAndForegroundRespectsCooldown() async throws {
        let center = NotificationCenter()
        let bridge = SyncObserverBridge(notificationCenter: center)
        let eventsBox = SyncTestValueBox<[SyncObservedEvent]>([])

        bridge.startObserving { event in
            eventsBox.mutate { $0.append(event) }
        }
        defer { bridge.stop() }

        let mangaId = MangaIdentifier(sourceKey: "mangadex", mangaKey: "m1")
        center.post(name: .addToLibrary, object: mangaId)
        bridge.beginApplyingSync()
        center.post(name: .removeFromLibrary, object: mangaId)
        bridge.endApplyingSync()
        center.post(name: .updateMangaDetails, object: mangaId)

        #expect(eventsBox.get().count == 2)

        // Foreground sync cooldown skips rapid re-trigger within 5 seconds.
        let suiteName = "ForkSyncEngineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let config = SyncConfiguration(userDefaults: defaults)
        config.isEnabled = true
        config.serverURL = "https://pb.example.com"
        config.autoSyncOnForeground = true

        let nowBox = SyncTestValueBox(TimeInterval(1_000))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { dir.removeItem() }
        let tombstoneStore = SyncTombstoneStore(
            fileURL: dir.appendingPathComponent("tombstones.json"),
            nowProvider: { Date(timeIntervalSince1970: nowBox.get()) },
            recordingEnabledProvider: { config.isEnabled }
        )
        let logStore = SyncLogStore(fileURL: dir.appendingPathComponent("logs.json"))
        let source = MockSnapshotSource(backup: SyncTestFixtures.makeBackup(manga: [SyncTestFixtures.makeManga(id: "m1")]))
        let applier = MockSnapshotApplier(source: source)
        let provider = MockStorageProvider()
        let keychain = InMemoryKeychainStore()
        try keychain.writeString("user-jwt", account: SyncKeychainAccount.pocketBaseAuthToken)
        try keychain.writeString("user-1", account: SyncKeychainAccount.pocketBaseUserId)

        let engine = SyncEngine(
            configuration: config,
            keychain: keychain,
            provider: provider,
            tombstoneStore: tombstoneStore,
            logStore: logStore,
            snapshotSource: source,
            snapshotApplier: applier,
            foregroundCooldownSeconds: 5,
            nowProvider: { Date(timeIntervalSince1970: nowBox.get()) }
        )

        await engine.syncIfNeeded(reason: .foreground)
        #expect(await provider.uploadCount == 1)

        // Simulate new local change within 2s cooldown window -> foreground sync skipped.
        nowBox.set(1_002)
        let manga2 = MangaIdentifier(sourceKey: "mangadex", mangaKey: "m2")
        await source.updateBackup(
            SyncTestFixtures.makeBackup(
                library: [SyncTestFixtures.makeLibraryManga(mangaId: "m2")],
                manga: [
                    SyncTestFixtures.makeManga(id: "m1"),
                    SyncTestFixtures.makeManga(id: "m2")
                ]
            )
        )
        tombstoneStore.recordLibraryAddition(mangaId: manga2)
        await engine.syncIfNeeded(reason: .foreground)
        #expect(await provider.uploadCount == 1)

        // Advance past cooldown window -> foreground sync runs and uploads rev 2.
        nowBox.set(1_010)
        await engine.syncIfNeeded(reason: .foreground)
        #expect(await provider.uploadCount == 2)
    }
}
