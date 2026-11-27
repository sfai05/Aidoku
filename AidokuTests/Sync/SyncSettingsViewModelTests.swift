//
//  SyncSettingsViewModelTests.swift
//  AidokuTests
//

@testable import Aidoku
import Foundation
import Testing

private actor ViewModelMockHTTPClient: SyncHTTPClient {
    typealias Handler = @Sendable (URLRequest) async throws -> (Int, Data)

    private var handlers: [Handler]

    init(handlers: [Handler]) {
        self.handlers = handlers
    }

    func enqueue(_ handler: @escaping Handler) {
        handlers.append(handler)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else {
            throw SyncError.invalidServerURL("missing")
        }
        guard !handlers.isEmpty else {
            throw SyncError.networkError("Unexpected HTTP request to \(url.absoluteString)")
        }
        let next = handlers.removeFirst()
        let (statusCode, data) = try await next(request)
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (data, response)
    }
}

private actor ViewModelMockSnapshotSource: SyncSnapshotSource {
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

private actor ViewModelMockSnapshotApplier: SyncSnapshotApplier {
    private(set) var replacedEnvelopes: [SyncEnvelope] = []
    private let source: ViewModelMockSnapshotSource

    init(source: ViewModelMockSnapshotSource) {
        self.source = source
    }

    func applyMerged(_ envelope: SyncEnvelope) async throws -> Bool {
        await source.updateBackup(envelope.backup)
        return true
    }

    func replaceAll(with envelope: SyncEnvelope) async throws {
        replacedEnvelopes.append(envelope)
        await source.updateBackup(envelope.backup)
    }
}

@Suite(.serialized) @MainActor
struct SyncSettingsViewModelTests {
    @MainActor
    private struct Harness {
        let suiteName: String
        let tempDir: URL
        let notificationCenter: NotificationCenter
        let config: SyncConfiguration
        let keychain: InMemoryKeychainStore
        let tombstoneStore: SyncTombstoneStore
        let logStore: SyncLogStore
        let httpClient: ViewModelMockHTTPClient
        let snapshotSource: ViewModelMockSnapshotSource
        let snapshotApplier: ViewModelMockSnapshotApplier
        let provider: PocketBaseSyncProvider
        let engine: SyncEngine
        let viewModel: SyncSettingsViewModel

        init(
            handlers: [ViewModelMockHTTPClient.Handler] = [],
            signedIn: Bool = false,
            enabled: Bool = false,
            serverURL: String? = nil,
            backup: Backup = SyncTestFixtures.makeBackup()
        ) {
            let suiteName = "ForkSyncVMTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            let config = SyncConfiguration(userDefaults: defaults)
            config.serverURL = serverURL
            config.isEnabled = enabled
            config.deviceName = "Test iPad"

            let keychain = InMemoryKeychainStore()
            if signedIn {
                try? keychain.writeString("initial-jwt", account: SyncKeychainAccount.pocketBaseAuthToken)
                try? keychain.writeString("user-1", account: SyncKeychainAccount.pocketBaseUserId)
                try? keychain.writeString("reader@example.com", account: SyncKeychainAccount.pocketBaseUserEmail)
            }

            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let tombstoneStore = SyncTombstoneStore(
                fileURL: tempDir.appendingPathComponent("tombstones.json"),
                nowProvider: { SyncTestFixtures.date(5_000) },
                recordingEnabledProvider: { config.isEnabled }
            )
            let logStore = SyncLogStore(fileURL: tempDir.appendingPathComponent("sync_logs.json"))
            let httpClient = ViewModelMockHTTPClient(handlers: handlers)
            let provider = PocketBaseSyncProvider(
                configuration: config,
                keychain: keychain,
                httpClient: httpClient,
                logStore: logStore,
                nowProvider: { SyncTestFixtures.date(5_000) }
            )
            let snapshotSource = ViewModelMockSnapshotSource(backup: backup)
            let snapshotApplier = ViewModelMockSnapshotApplier(source: snapshotSource)
            let engine = SyncEngine(
                configuration: config,
                keychain: keychain,
                provider: provider,
                tombstoneStore: tombstoneStore,
                logStore: logStore,
                snapshotSource: snapshotSource,
                snapshotApplier: snapshotApplier,
                nowProvider: { SyncTestFixtures.date(6_000) }
            )
            let notificationCenter = NotificationCenter()
            let viewModel = SyncSettingsViewModel(
                engine: engine,
                logStore: logStore,
                notificationCenter: notificationCenter
            )

            self.suiteName = suiteName
            self.tempDir = tempDir
            self.notificationCenter = notificationCenter
            self.config = config
            self.keychain = keychain
            self.tombstoneStore = tombstoneStore
            self.logStore = logStore
            self.httpClient = httpClient
            self.snapshotSource = snapshotSource
            self.snapshotApplier = snapshotApplier
            self.provider = provider
            self.engine = engine
            self.viewModel = viewModel
        }

        func tearDown() {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
            tempDir.removeItem()
        }
    }

    @Test func forkL10nResolvesStringsFromBundle() {
        #expect(ForkL10n.string("SYNC_TITLE") != "SYNC_TITLE")
        #expect(!ForkL10n.string("SYNC_TITLE").isEmpty)
        #expect(ForkL10n.string("SYNC_STATUS_SYNCED") != "SYNC_STATUS_SYNCED")
        #expect(ForkL10n.string("SYNC_FORCE_PULL_SNAPSHOT_MESSAGE") != "SYNC_FORCE_PULL_SNAPSHOT_MESSAGE")

        let formatted = ForkL10n.format("SYNC_RESULT_FORMAT", "Merged", 7)
        #expect(formatted.contains("Merged"))
        #expect(formatted.contains("7"))
    }

    @Test func statusIndicatorsReflectDisabledErrorPendingAndSyncedStates() async throws {
        let harness = Harness(signedIn: false, enabled: false, serverURL: nil)
        defer { harness.tearDown() }

        await harness.viewModel.refreshState()
        #expect(harness.viewModel.status.indicator == .disabled)
        #expect(harness.viewModel.trafficLight == .gray)

        await harness.viewModel.setEnabled(true)
        #expect(!harness.viewModel.isEnabled)
        #expect(harness.viewModel.bannerMessage?.tone == .error)

        // Force enabled flag with missing session to verify error indicator safeguard.
        harness.config.isEnabled = true
        await harness.viewModel.refreshState()
        #expect(harness.viewModel.status.indicator == .error)
        #expect(harness.viewModel.trafficLight == .red)

        harness.config.serverURL = "https://pb.example.com"
        try harness.keychain.writeString("user-jwt", account: SyncKeychainAccount.pocketBaseAuthToken)
        try harness.keychain.writeString("user-1", account: SyncKeychainAccount.pocketBaseUserId)
        try harness.keychain.writeString("reader@example.com", account: SyncKeychainAccount.pocketBaseUserEmail)

        await harness.viewModel.refreshState()
        #expect(harness.viewModel.status.indicator == .synced)
        #expect(harness.viewModel.trafficLight == .green)

        harness.tombstoneStore.recordLibraryAddition(
            mangaId: MangaIdentifier(sourceKey: "mangadex", mangaKey: "m-new"),
            at: SyncTestFixtures.date(5_500)
        )
        await harness.viewModel.refreshState()
        #expect(harness.viewModel.status.indicator == .pendingChanges)
        #expect(harness.viewModel.trafficLight == .yellow)

        await harness.viewModel.setEnabled(false)
        #expect(harness.viewModel.status.indicator == .disabled)
        #expect(harness.viewModel.trafficLight == .gray)
    }

    @Test func signInClearsPasswordSwitchesAccountCursorAndSignsOut() async throws {
        let harness = Harness(
            handlers: [
                { request in
                    #expect(request.url?.path == "/api/collections/users/auth-with-password")
                    return (200, Data(#"{"token":"jwt-user-new","record":{"id":"user-new","email":"new@example.com"}}"#.utf8))
                },
                { request in
                    #expect(request.url?.path == "/api/health")
                    return (200, Data(#"{"code":200,"message":"API is healthy."}"#.utf8))
                },
                { request in
                    #expect(request.url?.path == "/api/collections/users/auth-refresh")
                    return (200, Data(#"{"token":"jwt-user-refreshed","record":{"id":"user-new","email":"new@example.com"}}"#.utf8))
                },
                { request in
                    #expect(request.url?.path == "/api/collections/kodoku_sync_snapshots/records")
                    return (200, Data(#"{"items":[]}"#.utf8))
                }
            ],
            signedIn: true,
            enabled: true,
            serverURL: "https://old.pb.example.com"
        )
        defer { harness.tearDown() }

        harness.config.lastSyncedRevision = 5
        harness.tombstoneStore.recordLibraryDeletion(
            mangaId: MangaIdentifier(sourceKey: "mangadex", mangaKey: "m-old"),
            at: SyncTestFixtures.date(4_500)
        )
        try harness.keychain.writeString("user-old", account: SyncKeychainAccount.pocketBaseUserId)

        harness.viewModel.serverURLInput = "https://pb.example.com/"
        harness.viewModel.emailInput = "new@example.com"
        harness.viewModel.passwordInput = "super-secret-password"

        await harness.viewModel.signIn()

        #expect(harness.viewModel.passwordInput.isEmpty)
        #expect(harness.viewModel.signedInEmail == "new@example.com")
        #expect(harness.config.serverURL == "https://pb.example.com")
        #expect(harness.config.lastSyncedRevision == 0)
        let tombstoneSnap = harness.tombstoneStore.snapshot()
        #expect(tombstoneSnap.tombstones == .empty)
        #expect(!tombstoneSnap.hasPendingChanges)
        #expect(harness.viewModel.healthStatus?.isHealthy == true)

        let defaultsDump = UserDefaults(suiteName: harness.suiteName)?.dictionaryRepresentation() ?? [:]
        #expect(!defaultsDump.values.contains { String(describing: $0).contains("super-secret-password") })
        #expect(!defaultsDump.values.contains { String(describing: $0).contains("jwt-user") })

        await harness.viewModel.signOut()
        #expect(!harness.viewModel.isSignedIn)
        #expect(!harness.viewModel.isEnabled)
        #expect(harness.viewModel.healthStatus == nil)
        #expect(try harness.keychain.readString(account: SyncKeychainAccount.pocketBaseAuthToken) == nil)
    }

    @Test func setupWizardProvisioningHandlesResultsWithoutPersistingSuperuserSecrets() async throws {
        let harness = Harness(
            handlers: [
                { request in
                    #expect(request.url?.path == "/api/collections/_superusers/auth-with-password")
                    return (200, Data(#"{"token":"su-jwt-1","record":{"id":"su_1"}}"#.utf8))
                },
                { request in
                    #expect(request.url?.path == "/api/collections/kodoku_sync_snapshots")
                    return (404, Data(#"{"status":404}"#.utf8))
                },
                { request in
                    #expect(request.url?.path == "/api/collections/users")
                    return (200, Data(#"{"id":"users_col"}"#.utf8))
                },
                { request in
                    #expect(request.url?.path == "/api/collections")
                    return (200, Data(#"{"id":"col_sync"}"#.utf8))
                },
                { _ in
                    (200, Data(#"{"token":"su-jwt-2","record":{"id":"su_1"}}"#.utf8))
                },
                { _ in
                    let partialSchema = #"""
                    {
                        "id": "col_sync",
                        "listRule": "",
                        "viewRule": "@request.auth.id != \"\" && owner = @request.auth.id",
                        "createRule": "@request.auth.id != \"\" && @request.body.owner = @request.auth.id",
                        "updateRule": "@request.auth.id != \"\"",
                        "deleteRule": "@request.auth.id != \"\" && owner = @request.auth.id",
                        "fields": [
                            {"name":"owner","type":"relation"},
                            {"name":"payload","type":"file","protected":false}
                        ],
                        "indexes": []
                    }
                    """#
                    return (200, Data(partialSchema.utf8))
                }
            ],
            signedIn: false,
            enabled: false,
            serverURL: "https://pb.example.com"
        )
        defer { harness.tearDown() }

        let created = try await harness.viewModel.provisionCollection(
            superuserEmail: "admin@example.com",
            superuserPassword: "transient-su-password"
        )
        #expect(created == .created(collectionName: PocketBaseSchema.defaultCollectionName))

        let existing = try await harness.viewModel.provisionCollection(
            superuserEmail: "admin@example.com",
            superuserPassword: "transient-su-password"
        )
        guard case let .alreadyExists(name, missingFields, issues) = existing else {
            Issue.record("Expected alreadyExists result")
            return
        }
        #expect(name == PocketBaseSchema.defaultCollectionName)
        #expect(missingFields.contains("revision"))
        #expect(!issues.isEmpty)

        #expect(try harness.keychain.readString(account: SyncKeychainAccount.pocketBaseAuthToken) == nil)
        let defaultsDump = UserDefaults(suiteName: harness.suiteName)?.dictionaryRepresentation() ?? [:]
        #expect(!defaultsDump.values.contains { String(describing: $0).contains("transient-su-password") })
        #expect(!defaultsDump.values.contains { String(describing: $0).contains("su-jwt") })
    }

    @Test func insecureRemoteHTTPDetection() {
        #expect(!SyncSettingsViewModel.isInsecureRemoteHTTPURL(""))
        #expect(!SyncSettingsViewModel.isInsecureRemoteHTTPURL("https://pb.example.com"))
        #expect(!SyncSettingsViewModel.isInsecureRemoteHTTPURL("http://localhost:8090"))
        #expect(!SyncSettingsViewModel.isInsecureRemoteHTTPURL("http://127.0.0.1:8090"))
        #expect(!SyncSettingsViewModel.isInsecureRemoteHTTPURL("http://[::1]:8090"))
        #expect(!SyncSettingsViewModel.isInsecureRemoteHTTPURL("http://homeserver.local:8090"))
        #expect(!SyncSettingsViewModel.isInsecureRemoteHTTPURL("http://192.168.1.50:8090"))
        #expect(!SyncSettingsViewModel.isInsecureRemoteHTTPURL("http://10.0.0.5:8090"))
        #expect(!SyncSettingsViewModel.isInsecureRemoteHTTPURL("http://172.16.0.10:8090"))
        #expect(!SyncSettingsViewModel.isInsecureRemoteHTTPURL("http://172.31.255.254:8090"))

        #expect(SyncSettingsViewModel.isInsecureRemoteHTTPURL("http://pb.example.com:8090"))
        #expect(SyncSettingsViewModel.isInsecureRemoteHTTPURL("http://172.32.0.1:8090"))
    }

    @Test func recoveryActionsSnapshotRollbackDeleteCleanupResetAndLogs() async throws {
        let manga1 = SyncTestFixtures.makeLibraryManga(mangaId: "m-keep")
        let historicalBackup = SyncTestFixtures.makeBackup(library: [manga1])
        let historicalEnvelope = SyncEnvelope(
            schemaVersion: SyncEnvelope.currentSchemaVersion,
            revision: 1,
            deviceId: "other-ipad",
            deviceName: "Other iPad",
            updatedAt: SyncTestFixtures.date(2_000),
            tombstones: .empty,
            backup: historicalBackup
        )
        let historicalCompressed = try SyncEnvelopeCodec.encode(historicalEnvelope, compress: true)
        let historicalChecksum = SyncEnvelopeCodec.sha256Hex(historicalCompressed)

        let listJSON = """
        {
            "items": [
                {
                    "id": "rec_3",
                    "revision": 3,
                    "device_id": "iphone",
                    "device_name": "iPhone",
                    "schema_version": 1,
                    "checksum": "abc33333",
                    "payload": "snap3.aidoku.gz",
                    "created": "2026-11-27 10:03:00.000Z",
                    "updated": "2026-11-27 10:03:00.000Z"
                },
                {
                    "id": "rec_2",
                    "revision": 2,
                    "device_id": "iphone",
                    "device_name": "iPhone",
                    "schema_version": 1,
                    "checksum": "abc22222",
                    "payload": "snap2.aidoku.gz",
                    "created": "2026-11-27 10:02:00.000Z",
                    "updated": "2026-11-27 10:02:00.000Z"
                },
                {
                    "id": "rec_1",
                    "revision": 1,
                    "device_id": "other-ipad",
                    "device_name": "Other iPad",
                    "schema_version": 1,
                    "checksum": "\(historicalChecksum)",
                    "payload": "snap1.aidoku.gz",
                    "created": "2026-11-27 10:01:00.000Z",
                    "updated": "2026-11-27 10:01:00.000Z"
                }
            ]
        }
        """

        let createdJSON = """
        {
            "id": "rec_4",
            "revision": 4,
            "device_id": "test-ipad",
            "device_name": "Test iPad",
            "schema_version": 1,
            "checksum": "\(historicalChecksum)",
            "payload": "snap4.aidoku.gz",
            "created": "2026-11-27 10:04:00.000Z",
            "updated": "2026-11-27 10:04:00.000Z"
        }
        """

        let handlers: [ViewModelMockHTTPClient.Handler] = [
            // 1. loadRemoteSnapshots
            { _ in (200, Data(listJSON.utf8)) },
            // 2. forcePull(snapshot: rec_1):
            //    fetchLatestMetadata -> listSnapshots(limit: 50) -> file token -> download -> upload rollback rev 4 -> cleanup
            { _ in (200, Data(listJSON.utf8)) },
            { _ in (200, Data(listJSON.utf8)) },
            { _ in (200, Data(#"{"token":"file-tok-1"}"#.utf8)) },
            { _ in (200, historicalCompressed) },
            { _ in (200, Data(createdJSON.utf8)) },
            { _ in (200, Data(listJSON.utf8)) },
            { _ in (204, Data()) },
            // 3. deleteRemoteSnapshot rec_2
            { request in
                #expect(request.httpMethod == "DELETE")
                #expect(request.url?.path.hasSuffix("/records/rec_2") == true)
                return (204, Data())
            },
            // 4. cleanupRemoteSnapshots -> lists then deletes oldest, then loadRemoteSnapshots
            { _ in (200, Data(listJSON.utf8)) },
            { request in
                #expect(request.httpMethod == "DELETE")
                return (204, Data())
            },
            { _ in (200, Data(#"{"items":[]}"#.utf8)) }
        ]

        let harness = Harness(
            handlers: handlers,
            signedIn: true,
            enabled: true,
            serverURL: "https://pb.example.com"
        )
        defer { harness.tearDown() }

        harness.config.maxRemoteSnapshots = 2

        await harness.viewModel.loadRemoteSnapshots()
        #expect(harness.viewModel.remoteSnapshots.count == 3)

        let targetSnapshot = harness.viewModel.remoteSnapshots[2]
        await harness.viewModel.forcePull(snapshot: targetSnapshot)
        #expect(harness.config.lastSyncedRevision == 4)
        #expect(harness.viewModel.bannerMessage?.tone == .success)

        let deletedTarget = harness.viewModel.remoteSnapshots[1]
        await harness.viewModel.deleteRemoteSnapshot(deletedTarget)
        #expect(!harness.viewModel.remoteSnapshots.contains { $0.id == deletedTarget.id })

        await harness.viewModel.cleanupRemoteSnapshots()
        #expect(harness.viewModel.bannerMessage?.tone == .info)

        await harness.viewModel.resetLocalSyncState(clearCredentials: false)
        #expect(harness.config.lastSyncedRevision == 0)
        #expect(harness.viewModel.isSignedIn)

        await harness.viewModel.resetLocalSyncState(clearCredentials: true)
        #expect(!harness.viewModel.isSignedIn)
        #expect(!harness.viewModel.isEnabled)

        let logs = await harness.logStore.entries()
        #expect(!logs.isEmpty)
        let exported = await harness.logStore.exportText()
        #expect(exported.contains("Reset local sync state and cleared credentials."))

        await harness.logStore.clear()
        let cleared = await harness.logStore.entries()
        #expect(cleared.isEmpty)
    }

    @Test func forcePushUpdatesRevisionAndBanner() async throws {
        let manga1 = SyncTestFixtures.makeLibraryManga(mangaId: "m-local")
        let harness = Harness(
            handlers: [
                { request in
                    #expect(request.httpMethod == "GET")
                    return (200, Data(#"{"items":[]}"#.utf8))
                },
                { request in
                    #expect(request.httpMethod == "POST")
                    let created = """
                    {
                        "id": "rec_push_1",
                        "revision": 1,
                        "device_id": "test-ipad",
                        "device_name": "Test iPad",
                        "schema_version": 1,
                        "checksum": "abc11111",
                        "payload": "snap1.aidoku.gz",
                        "created": "2026-11-27 10:01:00.000Z",
                        "updated": "2026-11-27 10:01:00.000Z"
                    }
                    """
                    return (200, Data(created.utf8))
                },
                { request in
                    #expect(request.httpMethod == "GET")
                    return (200, Data(#"{"items":[]}"#.utf8))
                }
            ],
            signedIn: true,
            enabled: true,
            serverURL: "https://pb.example.com",
            backup: SyncTestFixtures.makeBackup(library: [manga1])
        )
        defer { harness.tearDown() }

        await harness.viewModel.forcePush()
        #expect(harness.config.lastSyncedRevision == 1)
        #expect(harness.viewModel.status.stats.libraryCount == 1)
        #expect(harness.viewModel.bannerMessage?.tone == .success)
    }
}

extension SyncSettingsViewModelTests {
    @Test func signOutThenSwitchServerWithSameUserResetsCursorAndTombstones() async throws {
        let handlers: [ViewModelMockHTTPClient.Handler] = [
            // Sign in #1 on server 1
            { _ in (200, Data(#"{"token":"jwt-s1","record":{"id":"same-user","email":"u@example.com"}}"#.utf8)) },
            { _ in (200, Data(#"{"code":200}"#.utf8)) },
            { _ in (200, Data(#"{"token":"jwt-s1-r","record":{"id":"same-user","email":"u@example.com"}}"#.utf8)) },
            { _ in (200, Data(#"{"items":[]}"#.utf8)) },
            // Sign in #2 on server 2 (same user id!)
            { _ in (200, Data(#"{"token":"jwt-s2","record":{"id":"same-user","email":"u@example.com"}}"#.utf8)) },
            { _ in (200, Data(#"{"code":200}"#.utf8)) },
            { _ in (200, Data(#"{"token":"jwt-s2-r","record":{"id":"same-user","email":"u@example.com"}}"#.utf8)) },
            { _ in (200, Data(#"{"items":[]}"#.utf8)) }
        ]
        let harness = Harness(handlers: handlers, signedIn: false, enabled: false, serverURL: nil)
        defer { harness.tearDown() }

        harness.viewModel.serverURLInput = "https://server1.example.com"
        harness.viewModel.emailInput = "u@example.com"
        harness.viewModel.passwordInput = "pw1"
        await harness.viewModel.signIn()

        harness.config.isEnabled = true
        harness.config.lastSyncedRevision = 5
        harness.tombstoneStore.recordLibraryDeletion(
            mangaId: MangaIdentifier(sourceKey: "mangadex", mangaKey: "m-s1"),
            at: SyncTestFixtures.date(4_500)
        )

        // Sign out deletes Keychain userId, yet server switch must still reset cursor & tombstones.
        await harness.viewModel.signOut()
        harness.viewModel.serverURLInput = "https://server2.example.com/"
        harness.viewModel.emailInput = "u@example.com"
        harness.viewModel.passwordInput = "pw1"
        await harness.viewModel.signIn()

        #expect(harness.config.lastSyncedRevision == 0)
        #expect(harness.config.lastSyncedServerURL == "https://server2.example.com")
        #expect(harness.tombstoneStore.snapshot().tombstones == .empty)
        #expect(!harness.tombstoneStore.snapshot().hasPendingChanges)
    }

    @Test func signOutThenSwitchOrKeepAccountOnSameServerHandlesCursorCorrectly() async throws {
        let handlers: [ViewModelMockHTTPClient.Handler] = [
            // Initial sign in as user-A
            { _ in (200, Data(#"{"token":"jwt-a1","record":{"id":"user-A","email":"a@example.com"}}"#.utf8)) },
            { _ in (200, Data(#"{"code":200}"#.utf8)) },
            { _ in (200, Data(#"{"token":"jwt-a1-r","record":{"id":"user-A","email":"a@example.com"}}"#.utf8)) },
            { _ in (200, Data(#"{"items":[]}"#.utf8)) },
            // Re-sign-in as SAME user-A on SAME server -> preserves cursor & tombstones
            { _ in (200, Data(#"{"token":"jwt-a2","record":{"id":"user-A","email":"a@example.com"}}"#.utf8)) },
            { _ in (200, Data(#"{"code":200}"#.utf8)) },
            { _ in (200, Data(#"{"token":"jwt-a2-r","record":{"id":"user-A","email":"a@example.com"}}"#.utf8)) },
            { _ in (200, Data(#"{"items":[]}"#.utf8)) },
            // Sign in as DIFFERENT user-B on SAME server -> resets cursor & tombstones
            { _ in (200, Data(#"{"token":"jwt-b1","record":{"id":"user-B","email":"b@example.com"}}"#.utf8)) },
            { _ in (200, Data(#"{"code":200}"#.utf8)) },
            { _ in (200, Data(#"{"token":"jwt-b1-r","record":{"id":"user-B","email":"b@example.com"}}"#.utf8)) },
            { _ in (200, Data(#"{"items":[]}"#.utf8)) }
        ]
        let harness = Harness(handlers: handlers, signedIn: false, enabled: false, serverURL: nil)
        defer { harness.tearDown() }

        harness.viewModel.serverURLInput = "https://pb.example.com"
        harness.viewModel.emailInput = "a@example.com"
        harness.viewModel.passwordInput = "pwA"
        await harness.viewModel.signIn()

        harness.config.isEnabled = true
        harness.config.lastSyncedRevision = 4
        harness.tombstoneStore.recordLibraryDeletion(
            mangaId: MangaIdentifier(sourceKey: "mangadex", mangaKey: "m-userA"),
            at: SyncTestFixtures.date(4_600)
        )

        // Same user re-sign-in preserves revision & pending tombstones.
        await harness.viewModel.signOut()
        harness.viewModel.passwordInput = "pwA"
        await harness.viewModel.signIn()
        #expect(harness.config.lastSyncedRevision == 4)
        #expect(harness.tombstoneStore.snapshot().hasPendingChanges)

        // Switching to user-B after signOut must reset revision & tombstones.
        await harness.viewModel.signOut()
        harness.viewModel.emailInput = "b@example.com"
        harness.viewModel.passwordInput = "pwB"
        await harness.viewModel.signIn()
        #expect(harness.config.lastSyncedRevision == 0)
        #expect(harness.config.lastSyncedUserId == "user-B")
        #expect(harness.tombstoneStore.snapshot().tombstones == .empty)
        #expect(!harness.tombstoneStore.snapshot().hasPendingChanges)
    }

    @Test func saveConnectionSettingsResetsCursorClearsSessionAndTrimsDeviceName() async throws {
        let harness = Harness(
            signedIn: true,
            enabled: true,
            serverURL: "https://pb1.example.com"
        )
        defer { harness.tearDown() }

        harness.config.lastSyncedRevision = 6
        harness.config.lastSyncedServerURL = "https://pb1.example.com"
        harness.config.lastSyncedCollectionName = PocketBaseSchema.defaultCollectionName
        harness.tombstoneStore.recordLibraryDeletion(
            mangaId: MangaIdentifier(sourceKey: "mangadex", mangaKey: "m-col"),
            at: SyncTestFixtures.date(4_700)
        )

        // Changing only collection name resets cursor while keeping auth session.
        harness.viewModel.collectionNameInput = "custom_sync"
        let savedCollection = await harness.viewModel.saveConnectionSettings()
        #expect(savedCollection)
        #expect(harness.config.collectionName == "custom_sync")
        #expect(harness.config.lastSyncedRevision == 0)
        #expect(harness.tombstoneStore.snapshot().tombstones == .empty)
        #expect(harness.viewModel.isSignedIn)

        // Changing server URL while signed in clears Keychain session, disables sync, and resets cursor.
        harness.config.lastSyncedRevision = 6
        harness.tombstoneStore.recordLibraryDeletion(
            mangaId: MangaIdentifier(sourceKey: "mangadex", mangaKey: "m-srv"),
            at: SyncTestFixtures.date(4_800)
        )
        harness.viewModel.serverURLInput = "https://pb2.example.com/"
        let savedServer = await harness.viewModel.saveConnectionSettings()
        #expect(savedServer)
        #expect(!harness.viewModel.isSignedIn)
        #expect(!harness.viewModel.isEnabled)
        #expect(harness.config.lastSyncedRevision == 0)
        #expect(harness.tombstoneStore.snapshot().tombstones == .empty)
        #expect(try harness.keychain.readString(account: SyncKeychainAccount.pocketBaseAuthToken) == nil)

        // Device name whitespace trimming on live edit.
        harness.viewModel.deviceNameInput = "  iPad Pro  "
        harness.viewModel.persistDeviceNameInput()
        #expect(harness.config.deviceName == "iPad Pro")
    }
}
