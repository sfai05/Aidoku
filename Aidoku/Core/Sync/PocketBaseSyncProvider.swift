//
//  PocketBaseSyncProvider.swift
//  Aidoku
//

import Foundation

protocol SyncHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

final class URLSessionSyncHTTPClient: SyncHTTPClient {
    let session: URLSession

    static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }

    init(session: URLSession = URLSessionSyncHTTPClient.makeDefaultSession()) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SyncError.networkError(error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SyncError.networkError("Invalid HTTP response.")
        }
        return (data, httpResponse)
    }
}

struct PocketBaseAuthSession: Equatable, Sendable {
    let userId: String
    let email: String
}

enum PocketBaseProvisionResult: Equatable, Sendable {
    case created(collectionName: String)
    case alreadyExists(collectionName: String, missingFields: [String], configurationIssues: [String])
}

enum PocketBaseJWTInspector {
    struct ExpirationInfo: Equatable, Sendable {
        let issuedAt: Date?
        let expiresAt: Date
    }

    private struct Claims: Decodable {
        let exp: TimeInterval?
        let iat: TimeInterval?
    }

    static func expirationInfo(from token: String) -> ExpirationInfo? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return nil }

        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }

        guard
            let payloadData = Data(base64Encoded: base64),
            let claims = try? JSONDecoder().decode(Claims.self, from: payloadData),
            let exp = claims.exp
        else {
            return nil
        }

        return ExpirationInfo(
            issuedAt: claims.iat.map { Date(timeIntervalSince1970: $0) },
            expiresAt: Date(timeIntervalSince1970: exp)
        )
    }
}

enum PocketBaseDateParser {
    private static let formatters: [DateFormatter] = {
        let patterns = [
            "yyyy-MM-dd HH:mm:ss.SSSZ",
            "yyyy-MM-dd HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ssZ"
        ]
        return patterns.map { pattern in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = pattern
            return formatter
        }
    }()

    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        for formatter in formatters {
            if let date = formatter.date(from: raw) {
                return date
            }
        }
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: raw) {
            return date
        }
        isoFormatter.formatOptions = [.withInternetDateTime]
        return isoFormatter.date(from: raw)
    }
}

final class PocketBaseSyncProvider: @unchecked Sendable {
    let providerId = "pocketbase"

    private let configuration: SyncConfiguration
    private let keychain: SyncKeychainStoreProtocol
    private let httpClient: SyncHTTPClient
    private let logStore: SyncLogStore
    private let nowProvider: @Sendable () -> Date

    init(
        configuration: SyncConfiguration = SyncConfiguration(),
        keychain: SyncKeychainStoreProtocol = SyncKeychainStore(),
        httpClient: SyncHTTPClient = URLSessionSyncHTTPClient(),
        logStore: SyncLogStore = .shared,
        nowProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.keychain = keychain
        self.httpClient = httpClient
        self.logStore = logStore
        self.nowProvider = nowProvider
    }

    // MARK: - Auth

    func currentSession() -> PocketBaseAuthSession? {
        guard
            let token = try? keychain.readString(account: SyncKeychainAccount.pocketBaseAuthToken),
            !token.isEmpty,
            let userId = try? keychain.readString(account: SyncKeychainAccount.pocketBaseUserId),
            !userId.isEmpty
        else {
            return nil
        }
        let email = (try? keychain.readString(account: SyncKeychainAccount.pocketBaseUserEmail)) ?? ""
        return PocketBaseAuthSession(userId: userId, email: email)
    }

    @discardableResult
    func signIn(serverURL: String, email: String, password: String) async throws -> PocketBaseAuthSession {
        let baseURL = try SyncConfiguration.normalizeServerURL(serverURL)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !password.isEmpty else {
            throw SyncError.authenticationFailed("Email and password are required.")
        }

        let endpoint = baseURL.appendingPathComponent("api/collections/users/auth-with-password")
        let payload = PasswordAuthRequest(identity: trimmedEmail, password: password)
        let body = try JSONEncoder().encode(payload)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await httpClient.data(for: request)
        guard response.statusCode == 200 else {
            let message = parseErrorMessage(from: data) ?? "Invalid credentials (HTTP \(response.statusCode))."
            if response.statusCode == 400 || response.statusCode == 401 {
                throw SyncError.authenticationFailed(message)
            }
            throw mapHTTPError(statusCode: response.statusCode, data: data, collectionName: nil)
        }

        let authResponse = try decodeResponse(AuthResponse.self, from: data)
        let resolvedEmail = authResponse.record.email?.isEmpty == false ? authResponse.record.email! : trimmedEmail
        let session = PocketBaseAuthSession(userId: authResponse.record.id, email: resolvedEmail)

        configuration.serverURL = baseURL.absoluteString
        try keychain.writeString(authResponse.token, account: SyncKeychainAccount.pocketBaseAuthToken)
        try keychain.writeString(session.userId, account: SyncKeychainAccount.pocketBaseUserId)
        try keychain.writeString(session.email, account: SyncKeychainAccount.pocketBaseUserEmail)

        await logStore.log(level: .info, category: "auth", message: "Signed in to PocketBase at \(baseURL.absoluteString).")
        return session
    }

    @discardableResult
    func refreshAuth() async throws -> PocketBaseAuthSession {
        let baseURL = try configuration.normalizedServerURL()
        let auth = try loadAuthCredentials()
        let endpoint = baseURL.appendingPathComponent("api/collections/users/auth-refresh")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(auth.token, forHTTPHeaderField: "Authorization")

        let (data, response) = try await httpClient.data(for: request)
        guard response.statusCode == 200 else {
            if response.statusCode == 401 {
                try? signOut()
                throw SyncError.authenticationExpired
            }
            throw mapHTTPError(statusCode: response.statusCode, data: data, collectionName: nil)
        }

        let authResponse = try decodeResponse(AuthResponse.self, from: data)
        let existingEmail = (try? keychain.readString(account: SyncKeychainAccount.pocketBaseUserEmail)) ?? ""
        let resolvedEmail = authResponse.record.email?.isEmpty == false ? authResponse.record.email! : existingEmail

        try keychain.writeString(authResponse.token, account: SyncKeychainAccount.pocketBaseAuthToken)
        try keychain.writeString(authResponse.record.id, account: SyncKeychainAccount.pocketBaseUserId)
        try keychain.writeString(resolvedEmail, account: SyncKeychainAccount.pocketBaseUserEmail)

        await logStore.log(level: .info, category: "auth", message: "Refreshed PocketBase auth session.")
        return PocketBaseAuthSession(userId: authResponse.record.id, email: resolvedEmail)
    }

    func refreshSessionIfNeeded() async throws {
        guard
            let token = try keychain.readString(account: SyncKeychainAccount.pocketBaseAuthToken),
            !token.isEmpty
        else {
            return
        }
        guard let info = PocketBaseJWTInspector.expirationInfo(from: token) else {
            return
        }

        let now = nowProvider()
        let shouldRefresh: Bool
        if now >= info.expiresAt {
            shouldRefresh = true
        } else if let issuedAt = info.issuedAt, info.expiresAt > issuedAt {
            let halfLifetime = info.expiresAt.timeIntervalSince(issuedAt) / 2
            let midpoint = issuedAt.addingTimeInterval(halfLifetime)
            shouldRefresh = now >= midpoint || info.expiresAt.timeIntervalSince(now) <= 86_400
        } else {
            shouldRefresh = info.expiresAt.timeIntervalSince(now) <= 3 * 86_400
        }

        guard shouldRefresh else { return }

        do {
            _ = try await refreshAuth()
        } catch SyncError.authenticationExpired {
            throw SyncError.authenticationExpired
        } catch {
            if now >= info.expiresAt {
                throw error
            }
            await logStore.log(
                level: .warning,
                category: "auth",
                message: "Proactive session refresh failed while token is still valid: \(error.localizedDescription)"
            )
        }
    }

    func signOut() throws {
        try keychain.delete(account: SyncKeychainAccount.pocketBaseAuthToken)
        try keychain.delete(account: SyncKeychainAccount.pocketBaseUserId)
        try keychain.delete(account: SyncKeychainAccount.pocketBaseUserEmail)
    }
}

// MARK: - One-Time Setup Wizard

extension PocketBaseSyncProvider {
    /// Programmatically provisions the sync collection using transient Superuser credentials.
    /// Superuser credentials and admin tokens remain strictly in local memory for this call.
    func provisionCollection(
        serverURL: String,
        collectionName: String,
        superuserEmail: String,
        superuserPassword: String
    ) async throws -> PocketBaseProvisionResult {
        let baseURL = try SyncConfiguration.normalizeServerURL(serverURL)
        let trimmedCollection = collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PocketBaseSchema.isValidCollectionName(trimmedCollection) else {
            throw SyncError.notConfigured("Collection name '\(collectionName)' must start with a letter and use alphanumeric or '_' characters.")
        }
        let trimmedEmail = superuserEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !superuserPassword.isEmpty else {
            throw SyncError.authenticationFailed("Superuser email and password are required.")
        }

        let superuserToken = try await authenticateSuperuser(
            baseURL: baseURL,
            email: trimmedEmail,
            password: superuserPassword
        )

        let existingEndpoint = baseURL.appendingPathComponent("api/collections/\(trimmedCollection)")
        var getRequest = URLRequest(url: existingEndpoint)
        getRequest.httpMethod = "GET"
        getRequest.timeoutInterval = 30
        getRequest.setValue(superuserToken, forHTTPHeaderField: "Authorization")

        let (existingData, existingResponse) = try await httpClient.data(for: getRequest)
        if existingResponse.statusCode == 200 {
            let collectionInfo = try? JSONDecoder().decode(CollectionInspectResponse.self, from: existingData)
            let validation = validateExistingCollection(collectionInfo, collectionName: trimmedCollection)
            await logStore.log(
                level: (!validation.missingFields.isEmpty || !validation.issues.isEmpty) ? .warning : .info,
                category: "setup",
                message: "PocketBase collection '\(trimmedCollection)' already exists "
                    + "(missing fields: \(validation.missingFields.count), config issues: \(validation.issues.count))."
            )
            return .alreadyExists(
                collectionName: trimmedCollection,
                missingFields: validation.missingFields,
                configurationIssues: validation.issues
            )
        } else if existingResponse.statusCode != 404 {
            throw mapHTTPError(statusCode: existingResponse.statusCode, data: existingData, collectionName: trimmedCollection)
        }

        let usersCollectionId = await resolveUsersCollectionId(baseURL: baseURL, superuserToken: superuserToken)
        let payload = PocketBaseSchema.collectionPayload(
            collectionName: trimmedCollection,
            usersCollectionId: usersCollectionId
        )

        let createEndpoint = baseURL.appendingPathComponent("api/collections")
        var createRequest = URLRequest(url: createEndpoint)
        createRequest.httpMethod = "POST"
        createRequest.timeoutInterval = 30
        createRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        createRequest.setValue(superuserToken, forHTTPHeaderField: "Authorization")
        createRequest.httpBody = try JSONEncoder().encode(payload)

        let (createData, createResponse) = try await httpClient.data(for: createRequest)
        guard createResponse.statusCode == 200 || createResponse.statusCode == 201 else {
            throw mapHTTPError(statusCode: createResponse.statusCode, data: createData, collectionName: trimmedCollection)
        }

        await logStore.log(
            level: .info,
            category: "setup",
            message: "Created PocketBase sync collection '\(trimmedCollection)'."
        )
        return .created(collectionName: trimmedCollection)
    }
}

// MARK: - SyncStorageProvider

extension PocketBaseSyncProvider: SyncStorageProvider {
    func healthCheck() async throws -> SyncHealthStatus {
        let baseURL = try configuration.normalizedServerURL()
        let collectionName = configuration.collectionName

        let healthURL = baseURL.appendingPathComponent("api/health")
        var healthRequest = URLRequest(url: healthURL)
        healthRequest.httpMethod = "GET"
        healthRequest.timeoutInterval = 15

        do {
            let (healthData, healthResponse) = try await httpClient.data(for: healthRequest)
            guard healthResponse.statusCode == 200 else {
                let message = parseErrorMessage(from: healthData) ?? "HTTP \(healthResponse.statusCode)"
                return SyncHealthStatus(
                    isReachable: false,
                    isAuthenticated: false,
                    collectionReady: false,
                    message: "Server health check failed: \(message)",
                    serverVersion: nil
                )
            }
        } catch {
            return SyncHealthStatus(
                isReachable: false,
                isAuthenticated: false,
                collectionReady: false,
                message: error.localizedDescription,
                serverVersion: nil
            )
        }

        do {
            _ = try await refreshAuth()
        } catch SyncError.notAuthenticated, SyncError.authenticationExpired {
            return SyncHealthStatus(
                isReachable: true,
                isAuthenticated: false,
                collectionReady: false,
                message: "PocketBase authentication required.",
                serverVersion: nil
            )
        } catch {
            return SyncHealthStatus(
                isReachable: true,
                isAuthenticated: false,
                collectionReady: false,
                message: error.localizedDescription,
                serverVersion: nil
            )
        }

        let auth = try loadAuthCredentials()
        let recordsURL = try buildRecordsURL(
            baseURL: baseURL,
            collectionName: collectionName,
            queryItems: [
                URLQueryItem(name: "perPage", value: "1"),
                URLQueryItem(name: "skipTotal", value: "1"),
                URLQueryItem(name: "fields", value: "id,revision")
            ]
        )
        var recordsRequest = URLRequest(url: recordsURL)
        recordsRequest.httpMethod = "GET"
        recordsRequest.timeoutInterval = 15
        recordsRequest.setValue(auth.token, forHTTPHeaderField: "Authorization")

        let (recordsData, recordsResponse) = try await httpClient.data(for: recordsRequest)
        switch recordsResponse.statusCode {
            case 200:
                return SyncHealthStatus(
                    isReachable: true,
                    isAuthenticated: true,
                    collectionReady: true,
                    message: "Connected and schema ready.",
                    serverVersion: nil
                )
            case 404:
                return SyncHealthStatus(
                    isReachable: true,
                    isAuthenticated: true,
                    collectionReady: false,
                    message: "Collection '\(collectionName)' not found. Run Setup Wizard or import pb_schema.json.",
                    serverVersion: nil
                )
            case 403:
                return SyncHealthStatus(
                    isReachable: true,
                    isAuthenticated: true,
                    collectionReady: false,
                    message: "Permission denied on collection '\(collectionName)'. Check API rules.",
                    serverVersion: nil
                )
            case 401:
                try? signOut()
                return SyncHealthStatus(
                    isReachable: true,
                    isAuthenticated: false,
                    collectionReady: false,
                    message: "Session expired. Please sign in again.",
                    serverVersion: nil
                )
            default:
                let message = parseErrorMessage(from: recordsData) ?? "HTTP \(recordsResponse.statusCode)"
                return SyncHealthStatus(
                    isReachable: true,
                    isAuthenticated: true,
                    collectionReady: false,
                    message: message,
                    serverVersion: nil
                )
        }
    }

    func fetchLatestMetadata() async throws -> SyncSnapshotMetadata? {
        try await listSnapshots(limit: 1).first
    }

    func listSnapshots(limit: Int) async throws -> [SyncSnapshotMetadata] {
        let baseURL = try configuration.normalizedServerURL()
        let collectionName = configuration.collectionName
        let auth = try loadAuthCredentials()
        let clampedLimit = min(max(limit, 1), 100)
        let escapedUserId = escapeFilterLiteral(auth.userId)

        let url = try buildRecordsURL(
            baseURL: baseURL,
            collectionName: collectionName,
            queryItems: [
                URLQueryItem(name: "filter", value: "(owner='\(escapedUserId)')"),
                URLQueryItem(name: "sort", value: "-revision,-created"),
                URLQueryItem(name: "perPage", value: "\(clampedLimit)"),
                URLQueryItem(name: "skipTotal", value: "1")
            ]
        )

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue(auth.token, forHTTPHeaderField: "Authorization")

        let (data, response) = try await httpClient.data(for: request)
        guard response.statusCode == 200 else {
            if response.statusCode == 401 {
                try? signOut()
                throw SyncError.authenticationExpired
            }
            throw mapHTTPError(statusCode: response.statusCode, data: data, collectionName: collectionName)
        }

        let listResponse = try decodeResponse(RecordListResponse.self, from: data)
        return listResponse.items.map { $0.toMetadata() }
    }

    func downloadSnapshot(metadata: SyncSnapshotMetadata) async throws -> Data {
        guard !metadata.id.isEmpty, !metadata.fileName.isEmpty else {
            throw SyncError.corruptedSnapshot("Snapshot record is missing file metadata.")
        }
        let baseURL = try configuration.normalizedServerURL()
        let collectionName = configuration.collectionName
        let auth = try loadAuthCredentials()

        let fileToken = try await fetchFileToken(baseURL: baseURL, authToken: auth.token)

        let fileBaseURL = baseURL
            .appendingPathComponent("api/files")
            .appendingPathComponent(collectionName)
            .appendingPathComponent(metadata.id)
            .appendingPathComponent(metadata.fileName)

        guard var components = URLComponents(url: fileBaseURL, resolvingAgainstBaseURL: false) else {
            throw SyncError.invalidServerURL(fileBaseURL.absoluteString)
        }
        components.queryItems = [
            URLQueryItem(name: "token", value: fileToken)
        ]
        guard let downloadURL = components.url else {
            throw SyncError.invalidServerURL(fileBaseURL.absoluteString)
        }

        var request = URLRequest(url: downloadURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 120

        let (data, response) = try await httpClient.data(for: request)
        guard response.statusCode == 200 else {
            if response.statusCode == 401 {
                try? signOut()
                throw SyncError.authenticationExpired
            }
            throw mapHTTPError(statusCode: response.statusCode, data: data, collectionName: collectionName)
        }

        if !metadata.checksum.isEmpty {
            let actualChecksum = SyncEnvelopeCodec.sha256Hex(data)
            guard actualChecksum == metadata.checksum else {
                throw SyncError.checksumMismatch(expected: metadata.checksum, actual: actualChecksum)
            }
        }

        return data
    }

    func uploadSnapshot(_ uploadRequest: SyncUploadRequest) async throws -> SyncSnapshotMetadata {
        let baseURL = try configuration.normalizedServerURL()
        let collectionName = configuration.collectionName
        let auth = try loadAuthCredentials()

        let endpoint = baseURL
            .appendingPathComponent("api/collections")
            .appendingPathComponent(collectionName)
            .appendingPathComponent("records")

        let boundary = "KodokuSync-\(UUID().uuidString)"
        let multipartBody = buildMultipartBody(
            boundary: boundary,
            fields: [
                ("owner", auth.userId),
                ("revision", "\(uploadRequest.revision)"),
                ("device_id", uploadRequest.deviceId),
                ("device_name", uploadRequest.deviceName),
                ("schema_version", "\(uploadRequest.schemaVersion)"),
                ("checksum", uploadRequest.checksum)
            ],
            file: MultipartFile(
                fieldName: "payload",
                fileName: uploadRequest.fileName,
                mimeType: "application/gzip",
                data: uploadRequest.data
            )
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(auth.token, forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody

        let (data, response) = try await httpClient.data(for: request)
        if response.statusCode == 200 || response.statusCode == 201 {
            let record = try decodeResponse(SnapshotRecordResponse.self, from: data)
            return record.toMetadata(fallbackSizeBytes: uploadRequest.data.count)
        }

        if response.statusCode == 401 {
            try? signOut()
            throw SyncError.authenticationExpired
        }

        if response.statusCode == 400 {
            if isUniqueConstraintViolation(data: data) {
                throw SyncError.revisionConflict(expectedRevision: uploadRequest.revision)
            }
            if let latest = try? await fetchLatestMetadata(), latest.revision >= uploadRequest.revision {
                throw SyncError.revisionConflict(expectedRevision: uploadRequest.revision)
            }
        }

        throw mapHTTPError(statusCode: response.statusCode, data: data, collectionName: collectionName)
    }

    func deleteSnapshot(id: String) async throws {
        guard !id.isEmpty else { return }
        let baseURL = try configuration.normalizedServerURL()
        let collectionName = configuration.collectionName
        let auth = try loadAuthCredentials()

        let endpoint = baseURL
            .appendingPathComponent("api/collections")
            .appendingPathComponent(collectionName)
            .appendingPathComponent("records")
            .appendingPathComponent(id)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30
        request.setValue(auth.token, forHTTPHeaderField: "Authorization")

        let (data, response) = try await httpClient.data(for: request)
        switch response.statusCode {
            case 200, 204, 404:
                return
            case 401:
                try? signOut()
                throw SyncError.authenticationExpired
            default:
                throw mapHTTPError(statusCode: response.statusCode, data: data, collectionName: collectionName)
        }
    }
}

// MARK: - Private Helpers

private extension PocketBaseSyncProvider {
    func loadAuthCredentials() throws -> (token: String, userId: String) {
        guard
            let token = try keychain.readString(account: SyncKeychainAccount.pocketBaseAuthToken),
            !token.isEmpty,
            let userId = try keychain.readString(account: SyncKeychainAccount.pocketBaseUserId),
            !userId.isEmpty
        else {
            throw SyncError.notAuthenticated
        }
        return (token, userId)
    }

    private func authenticateSuperuser(baseURL: URL, email: String, password: String) async throws -> String {
        let endpoint = baseURL.appendingPathComponent("api/collections/_superusers/auth-with-password")
        let body = try JSONEncoder().encode(PasswordAuthRequest(identity: email, password: password))

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await httpClient.data(for: request)
        guard response.statusCode == 200 else {
            let message = parseErrorMessage(from: data) ?? "Superuser authentication failed (HTTP \(response.statusCode))."
            if response.statusCode == 400 || response.statusCode == 401 {
                throw SyncError.authenticationFailed(message)
            }
            if response.statusCode == 404 {
                throw SyncError.serverError(
                    statusCode: 404,
                    message: "Superuser endpoint '/api/collections/_superusers/auth-with-password' not found. PocketBase v0.23+ is required."
                )
            }
            throw mapHTTPError(statusCode: response.statusCode, data: data, collectionName: nil)
        }

        let authResponse = try decodeResponse(AuthResponse.self, from: data)
        return authResponse.token
    }

    private func resolveUsersCollectionId(baseURL: URL, superuserToken: String) async -> String {
        let endpoint = baseURL.appendingPathComponent("api/collections/users")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(superuserToken, forHTTPHeaderField: "Authorization")

        guard
            let (data, response) = try? await httpClient.data(for: request),
            response.statusCode == 200,
            let info = try? JSONDecoder().decode(CollectionInspectResponse.self, from: data),
            let id = info.id,
            !id.isEmpty
        else {
            return PocketBaseSchema.defaultUsersCollectionId
        }
        return id
    }

    private func fetchFileToken(baseURL: URL, authToken: String) async throws -> String {
        let endpoint = baseURL.appendingPathComponent("api/files/token")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(authToken, forHTTPHeaderField: "Authorization")

        let (data, response) = try await httpClient.data(for: request)
        guard response.statusCode == 200 else {
            if response.statusCode == 401 {
                try? signOut()
                throw SyncError.authenticationExpired
            }
            throw mapHTTPError(statusCode: response.statusCode, data: data, collectionName: nil)
        }

        let decoded = try decodeResponse(FileTokenResponse.self, from: data)
        guard !decoded.token.isEmpty else {
            throw SyncError.authenticationExpired
        }
        return decoded.token
    }

    private func buildRecordsURL(
        baseURL: URL,
        collectionName: String,
        queryItems: [URLQueryItem]
    ) throws -> URL {
        let recordsURL = baseURL
            .appendingPathComponent("api/collections")
            .appendingPathComponent(collectionName)
            .appendingPathComponent("records")
        guard var components = URLComponents(url: recordsURL, resolvingAgainstBaseURL: false) else {
            throw SyncError.invalidServerURL(recordsURL.absoluteString)
        }
        components.queryItems = queryItems
        guard let finalURL = components.url else {
            throw SyncError.invalidServerURL(recordsURL.absoluteString)
        }
        return finalURL
    }

    struct MultipartFile {
        let fieldName: String
        let fileName: String
        let mimeType: String
        let data: Data
    }

    func buildMultipartBody(
        boundary: String,
        fields: [(String, String)],
        file: MultipartFile
    ) -> Data {
        var body = Data()
        let lineBreak = "\r\n"

        for (name, value) in fields {
            body.appendString("--\(boundary)\(lineBreak)")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"\(lineBreak)\(lineBreak)")
            body.appendString("\(value)\(lineBreak)")
        }

        let safeFileName = file.fileName.replacingOccurrences(of: "\"", with: "_")
        body.appendString("--\(boundary)\(lineBreak)")
        body.appendString("Content-Disposition: form-data; name=\"\(file.fieldName)\"; filename=\"\(safeFileName)\"\(lineBreak)")
        body.appendString("Content-Type: \(file.mimeType)\(lineBreak)\(lineBreak)")
        body.append(file.data)
        body.appendString(lineBreak)
        body.appendString("--\(boundary)--\(lineBreak)")

        return body
    }

    private func escapeFilterLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    private func decodeResponse<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SyncError.corruptedSnapshot("Unexpected PocketBase response format: \(error.localizedDescription)")
        }
    }

    private func parseErrorMessage(from data: Data) -> String? {
        guard let decoded = try? JSONDecoder().decode(ErrorResponse.self, from: data) else {
            return nil
        }
        if let fieldErrors = decoded.data, !fieldErrors.isEmpty {
            let details = fieldErrors
                .sorted { $0.key < $1.key }
                .compactMap { key, info in info.message.map { "\(key): \($0)" } }
                .joined(separator: "; ")
            if !details.isEmpty {
                return "\(decoded.message ?? "Error") (\(details))"
            }
        }
        return decoded.message
    }

    private func isUniqueConstraintViolation(data: Data) -> Bool {
        if let decoded = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
            if let fieldErrors = decoded.data {
                for (_, info) in fieldErrors {
                    if info.code == "validation_not_unique" {
                        return true
                    }
                    if let message = info.message?.lowercased(), message.contains("unique") {
                        return true
                    }
                }
            }
            if let message = decoded.message?.lowercased(), message.contains("unique") {
                return true
            }
        }
        return false
    }

    private func mapHTTPError(statusCode: Int, data: Data, collectionName: String?) -> SyncError {
        let message = parseErrorMessage(from: data) ?? "HTTP \(statusCode)"
        switch statusCode {
            case 401:
                return .authenticationExpired
            case 403:
                return .permissionDenied(message)
            case 404:
                if let collectionName {
                    return .collectionNotFound(collectionName)
                }
                return .serverError(statusCode: statusCode, message: message)
            case 413:
                return .serverError(
                    statusCode: 413,
                    message: "Sync snapshot exceeds server upload size limit (HTTP 413)."
                )
            default:
                return .serverError(statusCode: statusCode, message: message)
        }
    }

    private func validateExistingCollection(
        _ info: CollectionInspectResponse?,
        collectionName: String
    ) -> (missingFields: [String], issues: [String]) {
        guard let info else {
            return (
                PocketBaseSchema.requiredFieldNames.sorted(),
                ["Unable to inspect existing collection configuration."]
            )
        }

        let presentFields = Set(info.fields?.map(\.name) ?? [])
        let missing = PocketBaseSchema.requiredFieldNames.subtracting(presentFields).sorted()
        var issues: [String] = []

        let expected = PocketBaseSchema.collectionPayload(collectionName: collectionName)
        let normalizeRule: (String?) -> String? = { value in
            value?.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }

        if normalizeRule(info.listRule) != normalizeRule(expected.listRule) {
            issues.append("listRule does not match owner-scoped access rule.")
        }
        if normalizeRule(info.viewRule) != normalizeRule(expected.viewRule) {
            issues.append("viewRule does not match owner-scoped access rule.")
        }
        if normalizeRule(info.createRule) != normalizeRule(expected.createRule) {
            issues.append("createRule does not enforce owner = @request.auth.id.")
        }
        if info.updateRule != nil {
            issues.append("updateRule should be locked (null) to keep snapshots immutable.")
        }
        if normalizeRule(info.deleteRule) != normalizeRule(expected.deleteRule) {
            issues.append("deleteRule does not match owner-scoped access rule.")
        }

        if let payloadField = info.fields?.first(where: { $0.name == "payload" }), payloadField.protected != true {
            issues.append("payload file field should have 'protected: true'.")
        }

        let hasUniqueRevisionIndex = (info.indexes ?? []).contains { raw in
            let pattern = #"(?i)create\s+unique\s+index\b.*\(\s*[`"\[]?owner[`"\]]?\s*,\s*[`"\[]?revision[`"\]]?\s*\)"#
            return raw.range(of: pattern, options: .regularExpression) != nil
        }
        if !hasUniqueRevisionIndex {
            issues.append("Missing UNIQUE INDEX on (owner, revision) for optimistic locking.")
        }

        return (missing, issues)
    }
}

// MARK: - PocketBase Wire DTOs

private extension PocketBaseSyncProvider {
    struct PasswordAuthRequest: Encodable {
        let identity: String
        let password: String
    }

    struct AuthRecord: Decodable {
        let id: String
        let email: String?
    }

    struct AuthResponse: Decodable {
        let token: String
        let record: AuthRecord
    }

    struct FileTokenResponse: Decodable {
        let token: String
    }

    struct FieldSummary: Decodable {
        let name: String
        let type: String?
        let protected: Bool?
    }

    struct CollectionInspectResponse: Decodable {
        let id: String?
        let listRule: String?
        let viewRule: String?
        let createRule: String?
        let updateRule: String?
        let deleteRule: String?
        let fields: [FieldSummary]?
        let indexes: [String]?
    }

    struct FieldErrorInfo: Decodable {
        let code: String?
        let message: String?
    }

    struct ErrorResponse: Decodable {
        let status: Int?
        let message: String?
        let data: [String: FieldErrorInfo]?
    }

    struct RecordListResponse: Decodable {
        let items: [SnapshotRecordResponse]
    }

    struct SnapshotRecordResponse: Decodable {
        let id: String
        let revision: Int
        let deviceId: String
        let deviceName: String
        let schemaVersion: Int
        let checksum: String
        let fileName: String
        let created: String?
        let updated: String?

        enum CodingKeys: String, CodingKey {
            case id
            case revision
            case deviceId = "device_id"
            case deviceName = "device_name"
            case schemaVersion = "schema_version"
            case checksum
            case payload
            case created
            case updated
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            revision = try container.decode(Int.self, forKey: .revision)
            deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId) ?? ""
            deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName) ?? ""
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            checksum = try container.decodeIfPresent(String.self, forKey: .checksum) ?? ""
            created = try container.decodeIfPresent(String.self, forKey: .created)
            updated = try container.decodeIfPresent(String.self, forKey: .updated)

            if let singleFile = try? container.decode(String.self, forKey: .payload) {
                fileName = singleFile
            } else if let multipleFiles = try? container.decode([String].self, forKey: .payload) {
                fileName = multipleFiles.first ?? ""
            } else {
                fileName = ""
            }
        }

        func toMetadata(fallbackSizeBytes: Int? = nil) -> SyncSnapshotMetadata {
            let createdDate = PocketBaseDateParser.parse(created) ?? .distantPast
            let updatedDate = PocketBaseDateParser.parse(updated) ?? createdDate
            return SyncSnapshotMetadata(
                id: id,
                revision: revision,
                deviceId: deviceId,
                deviceName: deviceName,
                schemaVersion: schemaVersion,
                checksum: checksum,
                fileName: fileName,
                sizeBytes: fallbackSizeBytes,
                createdAt: createdDate,
                updatedAt: updatedDate
            )
        }
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
