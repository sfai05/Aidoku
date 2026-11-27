//
//  MangaBakaApi.swift
//  Aidoku
//
//  Created by Skitty on 2/24/26.
//

import Foundation

actor MangaBakaApi {
    let baseApiUrl = URL(string: "https://api.mangabaka.org")!

    // registered under skitty's MangaBaka account
    nonisolated let oauth = OAuthClient(
        id: "mangabaka",
        clientId: "rhqyADkXfqdmFVZcslegTvgLvLeOpFdz",
        baseUrl: "https://mangabaka.org/auth/oauth2",
        challengeMethod: .s256
    )

    private let session: URLSession
    nonisolated let authStore: MangaBakaAuthStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var inFlightRefreshTask: Task<OAuthResponse?, Never>?

    init(
        session: URLSession = .shared,
        authStore: MangaBakaAuthStore = .shared
    ) {
        self.session = session
        self.authStore = authStore
    }

    private struct ErrorPayload: Decodable {
        let message: String?
        let issues: [MangaBakaIssue]?
    }

    private func authorizedRequest(for url: URL) async -> URLRequest {
        if let apiKey = authStore.apiKey {
            var request = URLRequest(url: url)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            return request
        }
        return await oauth.authorizedRequest(for: url)
    }

    private static func bearerToken(from request: URLRequest) -> String? {
        guard let header = request.value(forHTTPHeaderField: "Authorization") else {
            return nil
        }
        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        return parts.count == 2 ? String(parts[1]) : header
    }

    // Fork: Coalesce OAuth token refreshes, preserve stored tokens on transient errors, and encode form params strictly
    private func refreshAccessToken(failedAccessToken: String? = nil) async -> OAuthResponse? {
        if let existingTask = inFlightRefreshTask {
            return await existingTask.value
        }

        if let failedAccessToken {
            if await oauth.tokens == nil {
                await oauth.loadTokens()
            }
            if
                let currentTokens = await oauth.tokens,
                let currentAccess = currentTokens.accessToken,
                !currentAccess.isEmpty,
                currentAccess != failedAccessToken
            {
                return currentTokens
            }
        }

        let task = Task<OAuthResponse?, Never> { [self] in
            if await oauth.tokens == nil {
                await oauth.loadTokens()
            }
            let existingTokens = await oauth.tokens
            guard let refreshToken = existingTokens?.refreshToken, !refreshToken.isEmpty else {
                return nil
            }
            guard let url = URL(string: oauth.baseUrl + "/token") else {
                return nil
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = MangaBakaAuthHelpers.formURLEncoded([
                "client_id": oauth.clientId,
                "refresh_token": refreshToken,
                "grant_type": "refresh_token",
                "redirect_uri": "aidoku://mangabaka-auth"
            ])

            guard let (data, response) = try? await session.data(for: request) else {
                return nil
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            guard statusCode == 200 else {
                if statusCode == 400 || statusCode == 401 {
                    await oauth.showReloginAlert(trackerName: "MangaBaka")
                }
                return nil
            }
            guard
                var refreshed = try? decoder.decode(OAuthResponse.self, from: data),
                let accessToken = refreshed.accessToken,
                !accessToken.isEmpty
            else {
                return nil
            }
            if refreshed.refreshToken == nil {
                refreshed.refreshToken = refreshToken
            }
            refreshed.askedForRefresh = false
            await oauth.setTokens(refreshed)
            UserDefaults.standard.set(accessToken, forKey: "Tracker.\(oauth.id).token")
            return refreshed
        }

        inFlightRefreshTask = task
        let result = await task.value
        inFlightRefreshTask = nil
        return result
    }

    private func requestResponse(urlRequest: URLRequest, requiresAuth: Bool = true) async throws -> (Data, Int?) {
        var effectiveRequest = urlRequest
        if requiresAuth, !authStore.hasApiKey {
            if await oauth.tokens == nil {
                await oauth.loadTokens()
            }
            if
                let tokens = await oauth.tokens,
                !tokens.askedForRefresh,
                let expiresIn = tokens.expiresIn,
                expiresIn > 0,
                tokens.expired
            {
                let reloginNeeded = await oauth.checkIfReloginNeeded(trackerName: "MangaBaka")
                if
                    !reloginNeeded,
                    let refreshed = await refreshAccessToken(failedAccessToken: tokens.accessToken),
                    let accessToken = refreshed.accessToken
                {
                    let tokenType = refreshed.tokenType ?? "Bearer"
                    effectiveRequest.setValue("\(tokenType) \(accessToken)", forHTTPHeaderField: "Authorization")
                }
            }
        }

        var (data, response) = try await session.data(for: effectiveRequest)
        var statusCode = (response as? HTTPURLResponse)?.statusCode

        guard requiresAuth, !authStore.hasApiKey else {
            return (data, statusCode)
        }

        if statusCode == 401 {
            let reloginNeeded = await oauth.checkIfReloginNeeded(trackerName: "MangaBaka")
            let alreadyAsked = await oauth.tokens?.askedForRefresh == true
            guard !reloginNeeded, !alreadyAsked else {
                return (data, statusCode)
            }

            var failedToken = Self.bearerToken(from: effectiveRequest)
            if failedToken == nil {
                failedToken = await oauth.tokens?.accessToken
            }
            if
                let refreshed = await refreshAccessToken(failedAccessToken: failedToken),
                let accessToken = refreshed.accessToken
            {
                let tokenType = refreshed.tokenType ?? "Bearer"
                var retryRequest = effectiveRequest
                retryRequest.setValue("\(tokenType) \(accessToken)", forHTTPHeaderField: "Authorization")
                let retry = try await session.data(for: retryRequest)
                data = retry.0
                statusCode = (retry.1 as? HTTPURLResponse)?.statusCode
            }
        }

        return (data, statusCode)
    }

    private func extractErrorMessage(from data: Data) -> String? {
        guard let payload = try? decoder.decode(ErrorPayload.self, from: data) else {
            return nil
        }
        return payload.message ?? payload.issues?.first?.message
    }

    private func object<T: Decodable>(from url: URL, requiresAuth: Bool = false) async throws -> T {
        let request = requiresAuth ? await authorizedRequest(for: url) : URLRequest(url: url)
        return try await object(from: request, requiresAuth: requiresAuth)
    }

    private func object<T: Decodable>(from request: URLRequest, requiresAuth: Bool = true) async throws -> T {
        let (data, statusCode) = try await requestResponse(urlRequest: request, requiresAuth: requiresAuth)
        if statusCode == 404 {
            throw MangaBakaApiError.notFound
        }
        if statusCode == 401 || statusCode == 403 {
            throw MangaBakaApiError.unauthorized(message: extractErrorMessage(from: data))
        }
        if let statusCode, !(200...299).contains(statusCode) {
            throw MangaBakaApiError.apiError(message: extractErrorMessage(from: data) ?? "HTTP \(statusCode)")
        }
        return try decoder.decode(T.self, from: data)
    }
}

extension MangaBakaApi {
    func search(query: String, nsfw: Bool = true) async throws -> [MangaBakaSeries] {
        guard
            let url = URL(string: "./v1/series/search", relativeTo: baseApiUrl),
            var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        else {
            throw MangaBakaApiError.invalidURL
        }
        var queryItems = [
            URLQueryItem(name: "q", value: query)
        ]
        if !nsfw {
            queryItems += [
                URLQueryItem(name: "not_content_rating", value: "erotica"),
                URLQueryItem(name: "not_content_rating", value: "pornographic")
            ]
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw MangaBakaApiError.invalidURL
        }
        let results: MangaBakaResponse<[MangaBakaSeries]> = try await object(from: url, requiresAuth: false)
        if let data = results.data {
            return data
        } else {
            throw MangaBakaApiError.apiError(message: results.message ?? results.issues?.first?.message ?? "Unknown error")
        }
    }

    func getSeries(id: Int) async throws -> MangaBakaSeries {
        guard let url = URL(string: "./v1/series/\(id)", relativeTo: baseApiUrl) else {
            throw MangaBakaApiError.invalidURL
        }
        let results: MangaBakaResponse<MangaBakaSeries> = try await object(from: url, requiresAuth: false)
        if let data = results.data {
            return data
        } else {
            throw MangaBakaApiError.apiError(message: results.message ?? results.issues?.first?.message ?? "Unknown error")
        }
    }

    func getLibraryEntry(seriesId: Int) async throws -> MangaBakaLibraryEntry {
        guard let url = URL(string: "./v1/my/library/\(seriesId)", relativeTo: baseApiUrl) else {
            throw MangaBakaApiError.invalidURL
        }
        let results: MangaBakaResponse<MangaBakaLibraryEntry> = try await object(from: url, requiresAuth: true)
        if let data = results.data {
            return data
        } else {
            throw MangaBakaApiError.apiError(message: results.message ?? results.issues?.first?.message ?? "Unknown error")
        }
    }

    func getLibraryEntries(seriesIds: [Int]) async throws -> [MangaBakaLibraryEntry] {
        guard !seriesIds.isEmpty else { return [] }
        guard
            let url = URL(string: "./v1/my/library/batch", relativeTo: baseApiUrl),
            var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        else {
            throw MangaBakaApiError.invalidURL
        }
        components.queryItems = seriesIds.map { URLQueryItem(name: "series_id", value: String($0)) }
        guard let url = components.url else {
            throw MangaBakaApiError.invalidURL
        }
        let request = await authorizedRequest(for: url)
        let results: MangaBakaResponse<[MangaBakaLibraryEntry]> = try await object(from: request, requiresAuth: true)
        if let data = results.data {
            return data
        } else {
            throw MangaBakaApiError.apiError(message: results.message ?? results.issues?.first?.message ?? "Unknown error")
        }
    }

    func updateLibraryEntry(seriesId: Int, create: Bool = false, data: MangaBakaLibraryEntry) async throws {
        guard let url = URL(string: "./v1/my/library/\(seriesId)", relativeTo: baseApiUrl) else {
            throw MangaBakaApiError.invalidURL
        }
        var request = await authorizedRequest(for: url)
        request.httpMethod = create ? "POST" : "PATCH"
        request.httpBody = try? encoder.encode(data)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (responseData, statusCode) = try await requestResponse(urlRequest: request, requiresAuth: true)
        if statusCode == 404 && !create {
            throw MangaBakaApiError.notFound
        }
        if statusCode == 401 || statusCode == 403 {
            throw MangaBakaApiError.unauthorized(message: extractErrorMessage(from: responseData))
        }
        if let statusCode, !(200...299).contains(statusCode) {
            throw MangaBakaApiError.apiError(message: extractErrorMessage(from: responseData) ?? "HTTP \(statusCode)")
        }
    }
}

// MARK: - Fork: Personal Access Token & Cover gallery endpoints
extension MangaBakaApi {
    func verifyApiKey(_ rawKey: String, timeout: TimeInterval = 10) async throws -> MangaBakaProfile {
        let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MangaBakaApiError.unauthorized(message: nil)
        }
        guard let url = URL(string: "./v1/my/profile", relativeTo: baseApiUrl) else {
            throw MangaBakaApiError.invalidURL
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(trimmed, forHTTPHeaderField: "x-api-key")
        let result: MangaBakaResponse<MangaBakaProfile> = try await object(from: request, requiresAuth: false)
        if let data = result.data {
            return data
        }
        throw MangaBakaApiError.apiError(message: result.message ?? "Unknown error")
    }

    static func buildSeriesImagesURL(
        baseApiUrl: URL,
        id: Int,
        page: Int = 1,
        limit: Int = 50,
        type: String? = nil,
        language: String? = nil
    ) throws -> URL {
        guard
            let base = URL(string: "./v1/series/\(id)/images", relativeTo: baseApiUrl),
            var components = URLComponents(url: base, resolvingAgainstBaseURL: true)
        else {
            throw MangaBakaApiError.invalidURL
        }
        let safePage = max(page, 1)
        let clampedLimit = min(max(limit, 1), 50)
        var queryItems = [
            URLQueryItem(name: "page", value: String(safePage)),
            URLQueryItem(name: "limit", value: String(clampedLimit))
        ]
        if let type = type?.trimmingCharacters(in: .whitespacesAndNewlines), !type.isEmpty {
            queryItems.append(URLQueryItem(name: "type", value: type))
        }
        if let language = language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty {
            queryItems.append(URLQueryItem(name: "language", value: language))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw MangaBakaApiError.invalidURL
        }
        return url
    }

    func getSeriesImages(
        id: Int,
        page: Int = 1,
        limit: Int = 50,
        type: String? = nil,
        language: String? = nil,
        timeout: TimeInterval = 10
    ) async throws -> MangaBakaSeriesImagesResult {
        let url = try Self.buildSeriesImagesURL(
            baseApiUrl: baseApiUrl,
            id: id,
            page: page,
            limit: limit,
            type: type,
            language: language
        )
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let results: MangaBakaImagesResponse = try await object(from: request, requiresAuth: false)
        if let data = results.data {
            return MangaBakaSeriesImagesResult(
                images: data,
                pagination: results.pagination,
                availableLanguages: results.availableLanguages ?? [],
                availableTypes: results.availableTypes ?? []
            )
        } else {
            throw MangaBakaApiError.apiError(message: results.message ?? "Unknown error")
        }
    }
}

enum MangaBakaApiError: LocalizedError, Equatable {
    case invalidURL
    case notFound
    case unauthorized(message: String?)
    case apiError(message: String)
    case todo

    var errorDescription: String? {
        switch self {
            case .invalidURL:
                "Invalid MangaBaka URL."
            case .notFound:
                "Requested MangaBaka resource was not found."
            case let .unauthorized(message):
                message ?? "MangaBaka authentication failed or expired."
            case let .apiError(message):
                message
            case .todo:
                "Not implemented."
        }
    }
}
