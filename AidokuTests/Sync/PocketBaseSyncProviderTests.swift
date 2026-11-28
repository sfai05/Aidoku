//
//  PocketBaseSyncProviderTests.swift
//  AidokuTests
//

@testable import Aidoku
import Foundation
import Testing

private actor MockHTTPClient: SyncHTTPClient {
    struct RecordedRequest: Sendable {
        let method: String
        let path: String
        let query: String?
        let authorization: String?
        let contentType: String?
        let body: Data?
    }

    typealias Handler = @Sendable (URLRequest) async throws -> (Int, Data)

    private var handlers: [Handler]
    private(set) var recordedRequests: [RecordedRequest] = []

    init(handlers: [Handler]) {
        self.handlers = handlers
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        recordedRequests.append(
            RecordedRequest(
                method: request.httpMethod ?? "GET",
                path: url.path,
                query: url.query,
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                contentType: request.value(forHTTPHeaderField: "Content-Type"),
                body: request.httpBody
            )
        )
        guard !handlers.isEmpty else {
            throw SyncError.networkError("Unexpected HTTP request to \(url.absoluteString)")
        }
        let next = handlers.removeFirst()
        let (statusCode, payload) = try await next(request)
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (payload, response)
    }
}

@Suite struct PocketBaseSyncProviderTests {
    private func makeIsolatedConfiguration() -> (SyncConfiguration, String) {
        let suiteName = "ForkSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let config = SyncConfiguration(userDefaults: defaults)
        return (config, suiteName)
    }

    private func cleanupDefaults(suiteName: String) {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    private func makeTempLogStore() -> (SyncLogStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logURL = dir.appendingPathComponent("sync_logs.json")
        return (SyncLogStore(fileURL: logURL), dir)
    }

    @Test func signInRefreshAndSignOutUseKeychainOnly() async throws {
        let (config, suite) = makeIsolatedConfiguration()
        defer { cleanupDefaults(suiteName: suite) }
        let keychain = InMemoryKeychainStore()
        let (logStore, logDir) = makeTempLogStore()
        defer { logDir.removeItem() }

        let client = MockHTTPClient(handlers: [
            { request in
                #expect(request.url?.path == "/api/collections/users/auth-with-password")
                let data = Data(#"{"token":"jwt-user-1","record":{"id":"user123","email":"reader@example.com"}}"#.utf8)
                return (200, data)
            },
            { request in
                #expect(request.url?.path == "/api/collections/users/auth-refresh")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "jwt-user-1")
                let data = Data(#"{"token":"jwt-user-2","record":{"id":"user123","email":"reader@example.com"}}"#.utf8)
                return (200, data)
            },
            { _ in
                (401, Data(#"{"status":401,"message":"The request requires valid authentication."}"#.utf8))
            }
        ])

        let provider = PocketBaseSyncProvider(
            configuration: config,
            keychain: keychain,
            httpClient: client,
            logStore: logStore
        )

        let session = try await provider.signIn(
            serverURL: "https://pb.example.com/",
            email: "reader@example.com",
            password: "secret"
        )
        #expect(session == PocketBaseAuthSession(userId: "user123", email: "reader@example.com"))
        #expect(config.serverURL == "https://pb.example.com")
        #expect(try keychain.readString(account: SyncKeychainAccount.pocketBaseAuthToken) == "jwt-user-1")

        // Verify token and password never leak into UserDefaults.
        let defaultsDump = UserDefaults(suiteName: suite)?.dictionaryRepresentation() ?? [:]
        #expect(!defaultsDump.values.contains { String(describing: $0).contains("jwt-user") })
        #expect(!defaultsDump.values.contains { String(describing: $0).contains("secret") })

        let refreshed = try await provider.refreshAuth()
        #expect(refreshed.userId == "user123")
        #expect(try keychain.readString(account: SyncKeychainAccount.pocketBaseAuthToken) == "jwt-user-2")

        await #expect(throws: SyncError.authenticationExpired) {
            try await provider.refreshAuth()
        }
        #expect(try keychain.readString(account: SyncKeychainAccount.pocketBaseAuthToken) == nil)
        #expect(provider.currentSession() == nil)
    }

    @Test func healthCheckReflectsMissingCollectionAndReadyStates() async throws {
        let (config, suite) = makeIsolatedConfiguration()
        defer { cleanupDefaults(suiteName: suite) }
        config.serverURL = "https://pb.example.com"
        let keychain = InMemoryKeychainStore()
        try keychain.writeString("jwt-1", account: SyncKeychainAccount.pocketBaseAuthToken)
        try keychain.writeString("u1", account: SyncKeychainAccount.pocketBaseUserId)
        let (logStore, logDir) = makeTempLogStore()
        defer { logDir.removeItem() }

        let client = MockHTTPClient(handlers: [
            // Missing collection check (404)
            { _ in (200, Data(#"{"code":200}"#.utf8)) },
            { _ in (200, Data(#"{"token":"jwt-2","record":{"id":"u1","email":"u@example.com"}}"#.utf8)) },
            { _ in (404, Data(#"{"status":404,"message":"Missing collection context."}"#.utf8)) },
            // Healthy check (200)
            { _ in (200, Data(#"{"code":200}"#.utf8)) },
            { _ in (200, Data(#"{"token":"jwt-3","record":{"id":"u1","email":"u@example.com"}}"#.utf8)) },
            { _ in (200, Data(#"{"items":[]}"#.utf8)) }
        ])

        let provider = PocketBaseSyncProvider(
            configuration: config,
            keychain: keychain,
            httpClient: client,
            logStore: logStore
        )

        let missingStatus = try await provider.healthCheck()
        #expect(missingStatus.isReachable)
        #expect(missingStatus.isAuthenticated)
        #expect(!missingStatus.collectionReady)
        #expect(!missingStatus.isHealthy)

        let readyStatus = try await provider.healthCheck()
        #expect(readyStatus.isHealthy)
    }

    @Test func fetchDownloadChecksumAndConflictUpload() async throws {
        let (config, suite) = makeIsolatedConfiguration()
        defer { cleanupDefaults(suiteName: suite) }
        config.serverURL = "https://pb.example.com"
        let keychain = InMemoryKeychainStore()
        try keychain.writeString("jwt-1", account: SyncKeychainAccount.pocketBaseAuthToken)
        try keychain.writeString("user_abc", account: SyncKeychainAccount.pocketBaseUserId)
        let (logStore, logDir) = makeTempLogStore()
        defer { logDir.removeItem() }

        let envelope = SyncEnvelope(
            revision: 7,
            deviceId: "ipad-1",
            deviceName: "iPad",
            backup: SyncTestFixtures.makeBackup(manga: [SyncTestFixtures.makeManga()])
        )
        let validGzip = try SyncEnvelopeCodec.encode(envelope, compress: true)
        let checksum = SyncEnvelopeCodec.sha256Hex(validGzip)

        let recordListJSON = """
        {
          "items": [
            {
              "id": "rec_007",
              "revision": 7,
              "device_id": "ipad-1",
              "device_name": "iPad",
              "schema_version": 1,
              "checksum": "\(checksum)",
              "payload": "snapshot_r7.aidoku.gz",
              "created": "2026-11-27 12:34:56.789Z",
              "updated": "2026-11-27 12:35:00.000Z"
            }
          ]
        }
        """

        let client = MockHTTPClient(handlers: [
            // fetchLatestMetadata
            { _ in (200, Data(recordListJSON.utf8)) },
            // downloadSnapshot -> /api/files/token then GET /api/files/...
            { request in
                #expect(request.url?.path == "/api/files/token")
                return (200, Data(#"{"token":"file-tok-1"}"#.utf8))
            },
            { request in
                #expect(request.url?.path == "/api/files/dokuha_sync_snapshots/rec_007/snapshot_r7.aidoku.gz")
                #expect(request.url?.query?.contains("token=file-tok-1") == true)
                return (200, validGzip)
            },
            // uploadSnapshot -> HTTP 400 validation_not_unique -> SyncError.revisionConflict
            { _ in
                let conflictJSON = #"{"status":400,"message":"Failed to create record.","data":{"revision":{"code":"validation_not_unique"}}}"#
                return (400, Data(conflictJSON.utf8))
            }
        ])

        let provider = PocketBaseSyncProvider(
            configuration: config,
            keychain: keychain,
            httpClient: client,
            logStore: logStore
        )

        let latest = try await provider.fetchLatestMetadata()
        #expect(latest?.id == "rec_007")
        #expect(latest?.revision == 7)
        #expect(latest?.createdAt != .distantPast)

        let downloaded = try await provider.downloadSnapshot(metadata: latest!)
        #expect(downloaded == validGzip)

        let uploadReq = SyncUploadRequest(
            revision: 7,
            deviceId: "iphone-1",
            deviceName: "iPhone",
            schemaVersion: 1,
            checksum: checksum,
            fileName: "snapshot_r7.aidoku.gz",
            data: validGzip
        )

        await #expect(throws: SyncError.revisionConflict(expectedRevision: 7)) {
            _ = try await provider.uploadSnapshot(uploadReq)
        }
    }

    @Test func downloadRejectsChecksumMismatch() async throws {
        let (config, suite) = makeIsolatedConfiguration()
        defer { cleanupDefaults(suiteName: suite) }
        config.serverURL = "https://pb.example.com"
        let keychain = InMemoryKeychainStore()
        try keychain.writeString("jwt-1", account: SyncKeychainAccount.pocketBaseAuthToken)
        try keychain.writeString("user_abc", account: SyncKeychainAccount.pocketBaseUserId)
        let (logStore, logDir) = makeTempLogStore()
        defer { logDir.removeItem() }

        let client = MockHTTPClient(handlers: [
            { _ in (200, Data(#"{"token":"file-tok"}"#.utf8)) },
            { _ in (200, Data("corrupted-bytes".utf8)) }
        ])

        let provider = PocketBaseSyncProvider(
            configuration: config,
            keychain: keychain,
            httpClient: client,
            logStore: logStore
        )

        let metadata = SyncSnapshotMetadata(
            id: "rec_1",
            revision: 1,
            deviceId: "d1",
            deviceName: "iPad",
            schemaVersion: 1,
            checksum: String(repeating: "a", count: 64),
            fileName: "snapshot.aidoku.gz",
            sizeBytes: 15,
            createdAt: Date(),
            updatedAt: Date()
        )

        await #expect {
            _ = try await provider.downloadSnapshot(metadata: metadata)
        } throws: { error in
            guard case SyncError.checksumMismatch = error else { return false }
            return true
        }
    }

    @Test func provisionCollectionWizardUsesTransientSuperuserCredentials() async throws {
        let (config, suite) = makeIsolatedConfiguration()
        defer { cleanupDefaults(suiteName: suite) }
        let keychain = InMemoryKeychainStore()
        let (logStore, logDir) = makeTempLogStore()
        defer { logDir.removeItem() }

        let client = MockHTTPClient(handlers: [
            { request in
                #expect(request.url?.path == "/api/collections/_superusers/auth-with-password")
                return (200, Data(#"{"token":"su-token-temp","record":{"id":"su1","email":"admin@example.com"}}"#.utf8))
            },
            { request in
                #expect(request.url?.path == "/api/collections/dokuha_sync_snapshots")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "su-token-temp")
                return (404, Data(#"{"status":404}"#.utf8))
            },
            { request in
                #expect(request.url?.path == "/api/collections/users")
                return (200, Data(#"{"id":"_pb_users_auth_"}"#.utf8))
            },
            { request in
                #expect(request.url?.path == "/api/collections")
                let body = request.httpBody ?? Data()
                let decoded = try JSONDecoder().decode(PocketBaseCollectionPayload.self, from: body)
                #expect(decoded.name == "dokuha_sync_snapshots")
                #expect(decoded.updateRule == nil)
                let ownerField = decoded.fields.first { $0.name == "owner" }
                let payloadField = decoded.fields.first { $0.name == "payload" }
                #expect(ownerField?.collectionId == "_pb_users_auth_")
                #expect(ownerField?.cascadeDelete == true)
                #expect(payloadField?.protected == true)
                #expect(decoded.indexes.count == 1)
                return (200, Data(#"{"id":"col_123","name":"dokuha_sync_snapshots"}"#.utf8))
            }
        ])

        let provider = PocketBaseSyncProvider(
            configuration: config,
            keychain: keychain,
            httpClient: client,
            logStore: logStore
        )

        let result = try await provider.provisionCollection(
            serverURL: "https://pb.example.com",
            collectionName: "dokuha_sync_snapshots",
            superuserEmail: "admin@example.com",
            superuserPassword: "super-secret-password"
        )

        #expect(result == .created(collectionName: "dokuha_sync_snapshots"))
        // Superuser credentials and admin tokens are strictly transient and never stored.
        #expect(try keychain.readString(account: SyncKeychainAccount.pocketBaseAuthToken) == nil)
        #expect(try keychain.readString(account: SyncKeychainAccount.pocketBaseUserId) == nil)
        #expect(try keychain.readString(account: SyncKeychainAccount.pocketBaseUserEmail) == nil)
        let exportedLogs = await logStore.exportText()
        #expect(!exportedLogs.contains("super-secret-password"))
        #expect(!exportedLogs.contains("su-token-temp"))
    }

    @Test func schemaJSONIsValid() throws {
        let jsonString = try PocketBaseSchema.exportSchemaJSON()
        let decoded = try JSONDecoder().decode([PocketBaseCollectionPayload].self, from: Data(jsonString.utf8))
        #expect(decoded.count == 1)
        let collection = try #require(decoded.first)
        #expect(collection.name == PocketBaseSchema.defaultCollectionName)
        #expect(collection.type == "base")
        #expect(collection.system == false)
        #expect(collection.listRule == "@request.auth.id != \"\" && owner = @request.auth.id")
        #expect(collection.viewRule == "@request.auth.id != \"\" && owner = @request.auth.id")
        #expect(collection.createRule == "@request.auth.id != \"\" && @request.body.owner = @request.auth.id")
        #expect(collection.updateRule == nil)
        #expect(collection.deleteRule == "@request.auth.id != \"\" && owner = @request.auth.id")

        let fieldsByName = Dictionary(uniqueKeysWithValues: collection.fields.map { ($0.name, $0) })
        let expectedFieldNames: Set<String> = [
            "owner",
            "revision",
            "device_id",
            "device_name",
            "schema_version",
            "checksum",
            "payload",
            "created",
            "updated"
        ]
        #expect(Set(fieldsByName.keys) == expectedFieldNames)

        let ownerField = try #require(fieldsByName["owner"])
        #expect(ownerField.type == "relation")
        #expect(ownerField.collectionId == "_pb_users_auth_")
        #expect(ownerField.cascadeDelete == true)
        #expect(ownerField.maxSelect == 1)
        #expect(ownerField.required == true)

        let payloadField = try #require(fieldsByName["payload"])
        #expect(payloadField.type == "file")
        #expect(payloadField.protected == true)
        #expect(payloadField.maxSize == 52_428_800)
        #expect(payloadField.maxSelect == 1)
        #expect(payloadField.required == true)

        let createdField = try #require(fieldsByName["created"])
        #expect(createdField.type == "autodate")
        #expect(createdField.onCreate == true)
        #expect(createdField.onUpdate == false)

        let updatedField = try #require(fieldsByName["updated"])
        #expect(updatedField.type == "autodate")
        #expect(updatedField.onCreate == true)
        #expect(updatedField.onUpdate == true)

        #expect(collection.indexes == [
            "CREATE UNIQUE INDEX idx_dokuha_sync_snapshots_owner_revision ON dokuha_sync_snapshots (owner, revision)"
        ])
    }
}

@Suite struct PocketBaseSyncHardeningTests {
    private func makeJWT(iat: TimeInterval, exp: TimeInterval) -> String {
        let header = Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8)
        let payload = Data(#"{"iat":\#(Int(iat)),"exp":\#(Int(exp))}"#.utf8)
        let encodeSegment: (Data) -> String = { data in
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(encodeSegment(header)).\(encodeSegment(payload)).sig"
    }

    @Test func refreshSessionIfNeededRefreshesExpiringJWTAndSkipsFreshJWT() async throws {
        let suiteName = "ForkSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let config = SyncConfiguration(userDefaults: defaults)
        config.serverURL = "https://pb.example.com"
        let keychain = InMemoryKeychainStore()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { dir.removeItem() }
        let logStore = SyncLogStore(fileURL: dir.appendingPathComponent("logs.json"))

        // 7-day token issued at t=0, expires at t=604_800.
        let initialJWT = makeJWT(iat: 0, exp: 604_800)
        let refreshedJWT = makeJWT(iat: 350_000, exp: 954_800)
        try keychain.writeString(initialJWT, account: SyncKeychainAccount.pocketBaseAuthToken)
        try keychain.writeString("user123", account: SyncKeychainAccount.pocketBaseUserId)
        try keychain.writeString("reader@example.com", account: SyncKeychainAccount.pocketBaseUserEmail)

        let clockBox = SyncTestValueBox<TimeInterval>(100_000) // < 50% lifetime and > 24h left

        let client = MockHTTPClient(handlers: [
            { request in
                #expect(request.url?.path == "/api/collections/users/auth-refresh")
                #expect(request.value(forHTTPHeaderField: "Authorization") == initialJWT)
                return (200, Data(#"{"token":"\#(refreshedJWT)","record":{"id":"user123","email":"reader@example.com"}}"#.utf8))
            },
            { _ in
                (500, Data(#"{"status":500,"message":"temporary server outage"}"#.utf8))
            }
        ])

        let provider = PocketBaseSyncProvider(
            configuration: config,
            keychain: keychain,
            httpClient: client,
            logStore: logStore,
            nowProvider: {
                Date(timeIntervalSince1970: clockBox.get())
            }
        )

        // Fresh token performs zero HTTP calls.
        try await provider.refreshSessionIfNeeded()
        #expect(await client.recordedRequests.isEmpty)

        // Past half-life (t = 350_000 > 302_400) triggers auth-refresh and updates Keychain.
        clockBox.set(350_000)
        try await provider.refreshSessionIfNeeded()
        #expect(try keychain.readString(account: SyncKeychainAccount.pocketBaseAuthToken) == refreshedJWT)
        #expect(await client.recordedRequests.count == 1)

        // While refreshed token is within warning threshold (t = 900_000, < 24h left) and server returns 500,
        // unexpired session is preserved with a warning instead of clearing auth.
        clockBox.set(900_000)
        try await provider.refreshSessionIfNeeded()
        #expect(try keychain.readString(account: SyncKeychainAccount.pocketBaseAuthToken) == refreshedJWT)
    }

    @Test func uploadSnapshotDetectsConflictViaGeneric400Fallback() async throws {
        let suiteName = "ForkSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let config = SyncConfiguration(userDefaults: defaults)
        config.serverURL = "https://pb.example.com"
        let keychain = InMemoryKeychainStore()
        try keychain.writeString("jwt-1", account: SyncKeychainAccount.pocketBaseAuthToken)
        try keychain.writeString("user_abc", account: SyncKeychainAccount.pocketBaseUserId)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { dir.removeItem() }
        let logStore = SyncLogStore(fileURL: dir.appendingPathComponent("logs.json"))

        let payloadData = Data("gzip-bytes".utf8)
        let checksum = SyncEnvelopeCodec.sha256Hex(payloadData)
        let latestListJSON = """
        {
          "items": [{
            "id": "rec_7",
            "revision": 7,
            "device_id": "ipad",
            "device_name": "iPad",
            "schema_version": 1,
            "checksum": "\(checksum)",
            "payload": "snapshot_r7.aidoku.gz"
          }]
        }
        """

        let client = MockHTTPClient(handlers: [
            { _ in
                (400, Data(#"{"status":400,"message":"Failed to create record.","data":{}}"#.utf8))
            },
            { _ in
                (200, Data(latestListJSON.utf8))
            }
        ])

        let provider = PocketBaseSyncProvider(
            configuration: config,
            keychain: keychain,
            httpClient: client,
            logStore: logStore
        )

        let uploadReq = SyncUploadRequest(
            revision: 7,
            deviceId: "iphone",
            deviceName: "iPhone",
            schemaVersion: 1,
            checksum: checksum,
            fileName: "snapshot_r7.aidoku.gz",
            data: payloadData
        )

        await #expect(throws: SyncError.revisionConflict(expectedRevision: 7)) {
            _ = try await provider.uploadSnapshot(uploadReq)
        }
        #expect(await client.recordedRequests.count == 2)
    }

    @Test func provisionCollectionFlagsMisconfiguredExistingCollectionAndAcceptsBacktickIndex() async throws {
        let suiteName = "ForkSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let config = SyncConfiguration(userDefaults: defaults)
        let keychain = InMemoryKeychainStore()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { dir.removeItem() }
        let logStore = SyncLogStore(fileURL: dir.appendingPathComponent("logs.json"))

        let misconfiguredJSON = """
        {
          "id": "col_1",
          "listRule": "",
          "viewRule": "@request.auth.id != \\"\\" && owner = @request.auth.id",
          "createRule": "@request.auth.id != \\"\\"",
          "updateRule": "@request.auth.id != \\"\\"",
          "deleteRule": "@request.auth.id != \\"\\" && owner = @request.auth.id",
          "fields": [
            {"name":"owner","type":"relation"},
            {"name":"revision","type":"number"},
            {"name":"device_id","type":"text"},
            {"name":"schema_version","type":"number"},
            {"name":"checksum","type":"text"},
            {"name":"payload","type":"file","protected":false}
          ],
          "indexes": []
        }
        """

        let validBacktickJSON = """
        {
          "id": "col_1",
          "listRule": "@request.auth.id != \\"\\" && owner = @request.auth.id",
          "viewRule": "@request.auth.id != \\"\\" && owner = @request.auth.id",
          "createRule": "@request.auth.id != \\"\\" && @request.body.owner = @request.auth.id",
          "updateRule": null,
          "deleteRule": "@request.auth.id != \\"\\" && owner = @request.auth.id",
          "fields": [
            {"name":"owner","type":"relation"},
            {"name":"revision","type":"number"},
            {"name":"device_id","type":"text"},
            {"name":"schema_version","type":"number"},
            {"name":"checksum","type":"text"},
            {"name":"payload","type":"file","protected":true}
          ],
          "indexes": [
            "CREATE UNIQUE INDEX `idx_owner_rev` ON `dokuha_sync_snapshots` (`owner`, `revision`)"
          ]
        }
        """

        let client = MockHTTPClient(handlers: [
            { _ in (200, Data(#"{"token":"su-tok","record":{"id":"su1"}}"#.utf8)) },
            { _ in (200, Data(misconfiguredJSON.utf8)) },
            { _ in (200, Data(#"{"token":"su-tok","record":{"id":"su1"}}"#.utf8)) },
            { _ in (200, Data(validBacktickJSON.utf8)) }
        ])

        let provider = PocketBaseSyncProvider(
            configuration: config,
            keychain: keychain,
            httpClient: client,
            logStore: logStore
        )

        let badResult = try await provider.provisionCollection(
            serverURL: "https://pb.example.com",
            collectionName: "dokuha_sync_snapshots",
            superuserEmail: "admin@example.com",
            superuserPassword: "pw"
        )
        guard case let .alreadyExists(_, missing, issues) = badResult else {
            Issue.record("Expected alreadyExists result")
            return
        }
        #expect(missing.isEmpty)
        #expect(issues.count >= 4)

        let goodResult = try await provider.provisionCollection(
            serverURL: "https://pb.example.com",
            collectionName: "dokuha_sync_snapshots",
            superuserEmail: "admin@example.com",
            superuserPassword: "pw"
        )
        #expect(goodResult == .alreadyExists(
            collectionName: "dokuha_sync_snapshots",
            missingFields: [],
            configurationIssues: []
        ))
    }

    @Test func normalizeServerURLRejectsEmbeddedCredentialsAndLogsRedactUserinfo() {
        #expect(throws: SyncError.invalidServerURL("Server URL must not contain embedded credentials.")) {
            _ = try SyncConfiguration.normalizeServerURL("https://user:pass@pb.example.com")
        }
        let redacted = SyncLogStore.redactSecrets("POST https://alice:supersecret@pb.example.com/api/records failed")
        #expect(!redacted.contains("supersecret"))
        #expect(!redacted.contains("alice:"))
        #expect(redacted.contains("https://<REDACTED>@pb.example.com"))
    }

    @Test func httpClientUsesNonCachingSession() {
        let client = URLSessionSyncHTTPClient()
        #expect(client.session.configuration.urlCache == nil)
        #expect(client.session.configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(client.session.configuration.httpCookieStorage == nil)
        #expect(!client.session.configuration.httpShouldSetCookies)
    }
}
