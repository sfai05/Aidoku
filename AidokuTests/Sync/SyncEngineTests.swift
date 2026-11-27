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
    private(set) var downloadCount = 0
    private(set) var uploadCount = 0

    init(
        initialSnapshots: [(SyncSnapshotMetadata, Data)] = [],
        concurrentConflictSnapshots: [Int: SyncEnvelope] = [:]
    ) {
        for (meta, data) in initialSnapshots {
            self.records[meta.id] = (meta, data)
        }
        self.concurrentConflictSnapshots = concurrentConflictSnapshots
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
        downloadCount += 1
        guard let entry = records[metadata.id] else {
            throw SyncError.collectionNotFound("missing-record-\(metadata.id)")
        }
        return entry.data
    }

    func uploadSnapshot(_ request: SyncUploadRequest) async throws -> SyncSnapshotMetadata {
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
            maxRemoteSnapshots: Int = 10
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
                nowProvider: { SyncTestFixtures.date(5_000) }
            )
            let logStore = SyncLogStore(fileURL: tempDir.appendingPathComponent("logs.json"))
            let source = MockSnapshotSource(backup: localBackup)
            let applier = MockSnapshotApplier(source: source)
            let provider = MockStorageProvider(concurrentConflictSnapshots: concurrentConflictSnapshots)
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
                nowProvider: { SyncTestFixtures.date(6_000) }
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
