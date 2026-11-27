//
//  MangaBakaTrackerTests.swift
//  AidokuTests
//
//  Created by Kodoku on 11/27/26.
//

@testable import Aidoku
import AidokuRunner
import Foundation
import Testing

@Suite struct MangaBakaTrackerModelTests {
    @Test func authStorePersistsTrimsDeletesAndExcludesUsernameFromBackups() throws {
        let suiteName = "MangaBakaAuthStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let keychain = InMemoryKeychainStore()
        let store = MangaBakaAuthStore(keychain: keychain, userDefaults: defaults)

        #expect(!store.hasApiKey)
        #expect(store.apiKey == nil)
        #expect(store.cachedUsername == nil)

        #expect(throws: MangaBakaApiError.unauthorized(message: "API Key cannot be empty.")) {
            try store.saveApiKey("   \n ")
        }

        try store.saveApiKey("  mb-secret-key-123  \n")
        #expect(store.hasApiKey)
        #expect(store.apiKey == "mb-secret-key-123")
        #expect((try? keychain.readString(account: MangaBakaAuthStore.keychainAccount)) == "mb-secret-key-123")

        // New instance backed by the same Keychain + defaults reads back persisted credentials.
        let reloadedStore = MangaBakaAuthStore(keychain: keychain, userDefaults: defaults)
        #expect(reloadedStore.apiKey == "mb-secret-key-123")

        reloadedStore.cachedUsername = " sfai05 "
        #expect(reloadedStore.cachedUsername == "sfai05")

        #expect(!BackupManager.allowedSettingsPrefixes.contains { prefix in
            MangaBakaAuthStore.usernameDefaultsKey.hasPrefix(prefix)
        })

        reloadedStore.clearApiKey()
        #expect(!reloadedStore.hasApiKey)
        #expect(reloadedStore.apiKey == nil)
        #expect(reloadedStore.cachedUsername == nil)
        #expect((try? keychain.readString(account: MangaBakaAuthStore.keychainAccount)) == nil)
    }

    @Test func authStoreThrowsOnKeychainWriteFailureAndDoesNotPoisonCacheOnReadError() throws {
        let suiteName = "MangaBakaAuthStoreFailureTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let keychain = StubKeychainStore()
        keychain.writeError = StubKeychainError.writeFailed
        let store = MangaBakaAuthStore(keychain: keychain, userDefaults: defaults)

        #expect(throws: StubKeychainError.writeFailed) {
            try store.saveApiKey("mb-secret")
        }
        #expect(store.apiKey == nil)
        #expect(!store.hasApiKey)

        keychain.writeError = nil
        try keychain.writeString("mb-recovered", account: MangaBakaAuthStore.keychainAccount)
        keychain.readFailuresRemaining = 1

        let readStore = MangaBakaAuthStore(keychain: keychain, userDefaults: defaults)
        // First read hits a transient Keychain error and must not cache nil.
        #expect(readStore.apiKey == nil)
        // Next read recovers without creating a new MangaBakaAuthStore.
        #expect(readStore.apiKey == "mb-recovered")
        #expect(readStore.hasApiKey)
    }

    @Test func helpersEncodeFormEscapeDatesAndNormalizeChapters() throws {
        let encodedData = try #require(MangaBakaAuthHelpers.formURLEncoded([
            "refresh_token": "abc+def/ghi=123&x",
            "grant_type": "refresh_token"
        ]))
        let encoded = String(data: encodedData, encoding: .utf8)
        #expect(encoded == "grant_type=refresh_token&refresh_token=abc%2Bdef%2Fghi%3D123%26x")

        let utcMinus8 = try #require(TimeZone(secondsFromGMT: -8 * 3600))
        let utcPlus14 = try #require(TimeZone(secondsFromGMT: 14 * 3600))
        let clearSentinel = Date(timeIntervalSince1970: 0)
        #expect(MangaBakaAuthHelpers.formatDate(clearSentinel, timeZone: utcMinus8) == "1970-01-01")
        #expect(MangaBakaAuthHelpers.formatDate(clearSentinel, timeZone: utcPlus14) == "1970-01-01")

        let epochIsoParsed = try #require(MangaBakaAuthHelpers.parseDate("1970-01-01T00:00:00.000Z", timeZone: utcPlus14))
        #expect(MangaBakaAuthHelpers.formatDate(epochIsoParsed, timeZone: utcPlus14) == "1970-01-01")

        let preEpochUtcMinus8 = try #require(MangaBakaAuthHelpers.parseDate("1969-12-31", timeZone: utcMinus8))
        #expect(MangaBakaAuthHelpers.formatDate(preEpochUtcMinus8, timeZone: utcMinus8) == "1969-12-31")
        let preEpochUtcPlus14 = try #require(MangaBakaAuthHelpers.parseDate("1969-12-31", timeZone: utcPlus14))
        #expect(MangaBakaAuthHelpers.formatDate(preEpochUtcPlus14, timeZone: utcPlus14) == "1969-12-31")

        let sampleDate = try #require(MangaBakaAuthHelpers.parseDate("2026-11-27T00:00:00.000Z", timeZone: utcMinus8))
        #expect(MangaBakaAuthHelpers.formatDate(sampleDate, timeZone: utcMinus8) == "2026-11-27")

        let plainDate = try #require(MangaBakaAuthHelpers.parseDate("2026-02-09", timeZone: utcMinus8))
        #expect(MangaBakaAuthHelpers.formatDate(plainDate, timeZone: utcMinus8) == "2026-02-09")
        #expect(MangaBakaAuthHelpers.parseDate("bad", timeZone: utcMinus8) == nil)

        #expect(MangaBakaAuthHelpers.normalizeChapterNumber(12) == 12)
        #expect(MangaBakaAuthHelpers.normalizeChapterNumber(12.5) == 12.5)
        #expect(MangaBakaAuthHelpers.normalizeChapterNumber(Float(12.1)) == 12.1)

        #expect(MangaBakaAuthHelpers.parseTotalCount("147") == 147)
        #expect(MangaBakaAuthHelpers.parseTotalCount("147.5") == 147)
        #expect(MangaBakaAuthHelpers.parseTotalCount("0") == nil)
        #expect(MangaBakaAuthHelpers.parseTotalCount(nil) == nil)
    }

    @Test func libraryEntryDecodesDecimalsAndEncodesFinishDateAndDecimalsCorrectly() throws {
        let json = """
        {
          "id": 99,
          "series_id": 1995,
          "state": "reading",
          "rating": 85.5,
          "progress_chapter": 12.5,
          "progress_volume": 3.5,
          "start_date": "2026-11-01T00:00:00.000Z",
          "finish_date": "2026-11-27T00:00:00.000Z"
        }
        """
        let entry = try JSONDecoder().decode(MangaBakaLibraryEntry.self, from: Data(json.utf8))
        #expect(entry.progressChapter == 12.5)
        #expect(entry.progressVolume == 3.5)
        #expect(entry.rating == 85.5)

        let payload = MangaBakaLibraryEntry(
            state: .completed,
            rating: 85.5,
            progressChapter: 147.5,
            progressVolume: 3.5,
            startDate: "2026-11-01",
            finishDate: "2026-11-27"
        )
        let data = try JSONEncoder().encode(payload)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["rating"] as? Double == 85.5)
        #expect(object["progress_chapter"] as? Double == 147.5)
        #expect(object["progress_volume"] as? Double == 3.5)
        #expect(object["start_date"] as? String == "2026-11-01")
        #expect(object["finish_date"] as? String == "2026-11-27")

        let clearPayload = MangaBakaLibraryEntry(
            startDate: "1970-01-01",
            finishDate: "1970-01-01"
        )
        let clearData = try JSONEncoder().encode(clearPayload)
        let clearObject = try #require(try JSONSerialization.jsonObject(with: clearData) as? [String: Any])
        #expect(clearObject["start_date"] is NSNull)
        #expect(clearObject["finish_date"] is NSNull)
    }

    @Test func profileDisplayNameAndMissingScopesHandlePatAndRestrictedTokens() throws {
        let patJson = """
        { "id": "u1", "nickname": "Nick", "preferred_username": "sfai05", "auth_type": "pat", "scopes": [] }
        """
        let pat = try JSONDecoder().decode(MangaBakaProfile.self, from: Data(patJson.utf8))
        #expect(pat.displayName == "sfai05")
        #expect(pat.missingLibraryScopes.isEmpty)

        let restrictedJson = """
        { "id": "u2", "nickname": "ReadOnly", "auth_type": "pat", "scopes": ["library.read"] }
        """
        let restricted = try JSONDecoder().decode(MangaBakaProfile.self, from: Data(restrictedJson.utf8))
        #expect(restricted.displayName == "ReadOnly")
        #expect(restricted.missingLibraryScopes == ["library.write"])
    }
}

@Suite(.serialized)
struct MangaBakaTrackerNetworkTests {
    private struct TestEnvironment {
        let tracker: MangaBakaTracker
        let api: MangaBakaApi
        let authStore: MangaBakaAuthStore
        let suiteName: String
        let restoreDefaults: () -> Void
    }

    private func makeTestEnvironment() -> TestEnvironment {
        TrackerURLProtocolStub.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TrackerURLProtocolStub.self]
        let session = URLSession(configuration: config)

        let suiteName = "MangaBakaTrackerNetworkTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keychain = InMemoryKeychainStore()
        let authStore = MangaBakaAuthStore(keychain: keychain, userDefaults: defaults)
        let api = MangaBakaApi(session: session, authStore: authStore)
        let tracker = MangaBakaTracker(api: api)

        let previousOAuthData = UserDefaults.standard.data(forKey: "Tracker.mangabaka.oauth")
        let previousToken = UserDefaults.standard.string(forKey: "Tracker.mangabaka.token")
        UserDefaults.standard.removeObject(forKey: "Tracker.mangabaka.oauth")
        UserDefaults.standard.removeObject(forKey: "Tracker.mangabaka.token")

        let restore: () -> Void = {
            if let previousOAuthData {
                UserDefaults.standard.set(previousOAuthData, forKey: "Tracker.mangabaka.oauth")
            } else {
                UserDefaults.standard.removeObject(forKey: "Tracker.mangabaka.oauth")
            }
            if let previousToken {
                UserDefaults.standard.set(previousToken, forKey: "Tracker.mangabaka.token")
            } else {
                UserDefaults.standard.removeObject(forKey: "Tracker.mangabaka.token")
            }
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }

        return TestEnvironment(
            tracker: tracker,
            api: api,
            authStore: authStore,
            suiteName: suiteName,
            restoreDefaults: restore
        )
    }

    @Test func apiKeyVerificationAndLibraryRequestsUseHeaderAndPreserveDecimalState() async throws {
        let env = makeTestEnvironment()
        defer { env.restoreDefaults() }

        TrackerURLProtocolStub.handler = { request in
            if request.url.path == "/v1/my/profile" {
                if request.header("x-api-key") == "mb-valid-token" {
                    let body = """
                    { "status": 200, "data": { "id": "u1", "preferred_username": "sfai05", "auth_type": "pat", "scopes": [] } }
                    """
                    return .http(status: 200, data: Data(body.utf8))
                }
                return .http(status: 401, data: Data(#"{"status":401,"message":"Invalid API key"}"#.utf8))
            }

            if request.url.path == "/v1/series/1995" {
                let body = """
                {
                  "status": 200,
                  "data": {
                    "id": 1995,
                    "title": "Frieren",
                    "cover": { "raw": { "url": null } },
                    "status": "completed",
                    "type": "manga",
                    "total_chapters": "147"
                  }
                }
                """
                return .http(status: 200, data: Data(body.utf8))
            }

            if request.url.path == "/v1/my/library/1995" {
                let body = """
                {
                  "status": 200,
                  "data": {
                    "id": 1,
                    "series_id": 1995,
                    "state": "reading",
                    "rating": 88.5,
                    "progress_chapter": 12.5,
                    "progress_volume": 2,
                    "start_date": "2026-11-01T00:00:00.000Z"
                  }
                }
                """
                return .http(status: 200, data: Data(body.utf8))
            }

            return .http(status: 404, data: Data())
        }

        await #expect(throws: MangaBakaApiError.unauthorized(message: "Invalid API key")) {
            try await env.tracker.saveApiKey("mb-wrong")
        }
        #expect(!env.tracker.isLoggedIn)

        let profile = try await env.tracker.saveApiKey(" mb-valid-token ")
        #expect(profile.displayName == "sfai05")
        #expect(env.tracker.isUsingApiKey)
        #expect(env.tracker.isLoggedIn)
        #expect(env.authStore.cachedUsername == "sfai05")

        let state = try await env.tracker.getState(trackId: "1995")
        #expect(state.lastReadChapter == 12.5)
        #expect(state.lastReadVolume == 2)
        #expect(state.score == 89)
        #expect(state.status == .reading)
        #expect(state.totalChapters == 147)

        let seriesRequest = try #require(TrackerURLProtocolStub.recordedRequests.first { $0.url.path == "/v1/series/1995" })
        #expect(seriesRequest.header("x-api-key") == nil)
        #expect(seriesRequest.header("Authorization") == nil)

        let libraryRequest = try #require(TrackerURLProtocolStub.recordedRequests.first { $0.url.path == "/v1/my/library/1995" })
        #expect(libraryRequest.header("x-api-key") == "mb-valid-token")
        #expect(libraryRequest.header("Authorization") == nil)
    }

    @Test func pat401DoesNotTriggerOAuthRefreshEvenWhenOAuthTokensExist() async throws {
        let env = makeTestEnvironment()
        defer { env.restoreDefaults() }

        let staleOAuth = OAuthResponse(
            tokenType: "Bearer",
            refreshToken: "stale-refresh",
            accessToken: "stale-access",
            expiresIn: 3600,
            askedForRefresh: false
        )
        await env.api.oauth.setTokens(staleOAuth)
        try env.authStore.saveApiKey("mb-revoked-key")

        TrackerURLProtocolStub.handler = { request in
            if request.url.path == "/v1/my/library/55" {
                return .http(status: 401, data: Data(#"{"status":401,"message":"Invalid API key"}"#.utf8))
            }
            return .http(status: 500, data: Data())
        }

        await #expect(throws: MangaBakaApiError.unauthorized(message: "Invalid API key")) {
            try await env.api.getLibraryEntry(seriesId: 55)
        }

        let refreshRequests = TrackerURLProtocolStub.recordedRequests.filter { $0.url.path == "/auth/oauth2/token" }
        #expect(refreshRequests.isEmpty)
        #expect(await env.api.oauth.tokens?.accessToken == "stale-access")
    }

    @Test func getStateHandles404PropagatesNetworkErrorUpdateCreatesAndRegisterHandlesStatuses() async throws {
        let env = makeTestEnvironment()
        defer { env.restoreDefaults() }

        TrackerURLProtocolStub.handler = { request in
            switch request.url.path {
                case "/v1/my/profile":
                    return .http(status: 200, data: Data(#"{"status":200,"data":{"id":"u1","auth_type":"pat","scopes":[]}}"#.utf8))

                case "/v1/series/42":
                    let body = """
                    {
                      "status": 200,
                      "data": {
                        "id": 42,
                        "title": "DICE",
                        "cover": { "raw": { "url": null } },
                        "status": "completed",
                        "type": "manhwa",
                        "total_chapters": "380",
                        "final_volume": "10"
                      }
                    }
                    """
                    return .http(status: 200, data: Data(body.utf8))

                case "/v1/series/777":
                    return .failure(.timedOut)

                case "/v1/my/library/42", "/v1/my/library/50":
                    if request.method == "GET" || request.method == "PATCH" {
                        return .http(status: 404, data: Data(#"{"status":404,"message":"Not found"}"#.utf8))
                    }
                    if request.method == "POST" {
                        return .http(status: 201, data: Data(#"{"status":201,"data":{"id":7,"series_id":42,"state":"reading"}}"#.utf8))
                    }

                case "/v1/my/library/60":
                    return .http(status: 200, data: Data(#"{"status":200,"data":{"id":60,"series_id":60,"state":"reading"}}"#.utf8))

                case "/v1/my/library/999":
                    return .http(status: 401, data: Data(#"{"status":401,"message":"Invalid API key"}"#.utf8))

                default:
                    break
            }
            return .http(status: 500, data: Data())
        }

        _ = try await env.tracker.saveApiKey("mb-pat")

        // Remote 404 returns empty progress + series totalChapters instead of failing.
        let state = try await env.tracker.getState(trackId: "42")
        #expect(state.lastReadChapter == nil)
        #expect(state.totalChapters == 380)
        #expect(state.totalVolumes == 10)

        // Network errors in getState must propagate rather than returning empty progress.
        await #expect(throws: URLError.self) {
            try await env.tracker.getState(trackId: "777")
        }

        // Update auto-recovers from PATCH 404 by sending POST create: true with finish_date properly encoded.
        let finishDate = try #require(MangaBakaAuthHelpers.parseDate("2026-11-27"))
        try await env.tracker.update(
            trackId: "42",
            update: TrackUpdate(lastReadChapter: 15.5, finishReadDate: finishDate)
        )
        #expect(TrackerURLProtocolStub.recordedRequests.contains { $0.url.path == "/v1/my/library/42" && $0.method == "PATCH" })
        let updatePost = try #require(
            TrackerURLProtocolStub.recordedRequests.first { $0.url.path == "/v1/my/library/42" && $0.method == "POST" }
        )
        let updateObj = try #require(try JSONSerialization.jsonObject(with: updatePost.body ?? Data()) as? [String: Any])
        #expect(updateObj["state"] as? String == "reading")
        #expect(updateObj["progress_chapter"] as? Double == 15.5)
        #expect(updateObj["finish_date"] as? String == "2026-11-27")
        #expect(updateObj["start_date"] == nil)

        // Register 404 creates `.reading` when chapter is provided and `.planToRead` when nil.
        _ = try await env.tracker.register(trackId: "50", highestChapterRead: 3.5, earliestReadDate: nil)
        let createReading = try #require(
            TrackerURLProtocolStub.recordedRequests.first { $0.url.path == "/v1/my/library/50" && $0.method == "POST" }
        )
        let readingObj = try #require(try JSONSerialization.jsonObject(with: createReading.body ?? Data()) as? [String: Any])
        #expect(readingObj["state"] as? String == "reading")
        #expect(readingObj["progress_chapter"] as? Double == 3.5)

        TrackerURLProtocolStub.clearRecordedRequests()
        _ = try await env.tracker.register(trackId: "50", highestChapterRead: nil, earliestReadDate: nil)
        let createPlan = try #require(
            TrackerURLProtocolStub.recordedRequests.first { $0.url.path == "/v1/my/library/50" && $0.method == "POST" }
        )
        let planObj = try #require(try JSONSerialization.jsonObject(with: createPlan.body ?? Data()) as? [String: Any])
        #expect(planObj["state"] as? String == "plan_to_read")
        #expect(planObj["progress_chapter"] == nil)

        // Existing 200 entry skips POST during register.
        TrackerURLProtocolStub.clearRecordedRequests()
        _ = try await env.tracker.register(trackId: "60", highestChapterRead: 5, earliestReadDate: nil)
        #expect(!TrackerURLProtocolStub.recordedRequests.contains { $0.url.path == "/v1/my/library/60" && $0.method == "POST" })

        // Unauthorized register throws instead of pretending entry doesn't exist.
        await #expect(throws: MangaBakaApiError.unauthorized(message: "Invalid API key")) {
            try await env.tracker.register(trackId: "999", highestChapterRead: 1, earliestReadDate: nil)
        }
    }

    @Test func oauthProactiveRefreshRefreshesExpiredTokenBeforeApiRequest() async throws {
        let env = makeTestEnvironment()
        defer { env.restoreDefaults() }

        let expiredOAuth = OAuthResponse(
            tokenType: "Bearer",
            refreshToken: "proactive-refresh",
            accessToken: "old-access",
            expiresIn: 60,
            createdAt: Date(timeIntervalSinceNow: -120),
            askedForRefresh: false
        )
        await env.api.oauth.setTokens(expiredOAuth)

        TrackerURLProtocolStub.handler = { request in
            if request.url.path == "/auth/oauth2/token" {
                let body = """
                { "access_token": "proactive-fresh", "token_type": "Bearer", "expires_in": 3600 }
                """
                return .http(status: 200, data: Data(body.utf8))
            }
            if request.url.path == "/v1/my/library/10" {
                if request.header("Authorization") == "Bearer proactive-fresh" {
                    let body = """
                    {"status":200,"data":{"id":1,"series_id":10,"state":"reading","progress_chapter":7}}
                    """
                    return .http(status: 200, data: Data(body.utf8))
                }
                return .http(status: 401, data: Data(#"{"status":401,"message":"Expired"}"#.utf8))
            }
            return .http(status: 404, data: Data())
        }

        let entry = try await env.api.getLibraryEntry(seriesId: 10)
        #expect(entry.progressChapter == 7)

        let requests = TrackerURLProtocolStub.recordedRequests
        let tokenIndex = try #require(requests.firstIndex { $0.url.path == "/auth/oauth2/token" })
        let libraryIndex = try #require(requests.firstIndex { $0.url.path == "/v1/my/library/10" })
        #expect(tokenIndex < libraryIndex)
        #expect(requests[libraryIndex].header("Authorization") == "Bearer proactive-fresh")
        #expect(requests.filter { $0.url.path == "/v1/my/library/10" }.count == 1)
    }

    @Test func oauthCoalescesConcurrentRefreshesIgnores400And403AndPreservesTokensOnFailure() async throws {
        let env = makeTestEnvironment()
        defer { env.restoreDefaults() }

        let initialOAuth = OAuthResponse(
            tokenType: "Bearer",
            refreshToken: "ref+with/special=chars",
            accessToken: "expired-access",
            expiresIn: 3600,
            askedForRefresh: false
        )
        await env.api.oauth.setTokens(initialOAuth)
        UserDefaults.standard.set("expired-access", forKey: "Tracker.mangabaka.token")

        final class RefreshBehavior: @unchecked Sendable {
            private let lock = NSLock()
            private var _statusCode = 200

            var statusCode: Int {
                get {
                    lock.lock()
                    defer { lock.unlock() }
                    return _statusCode
                }
                set {
                    lock.lock()
                    _statusCode = newValue
                    lock.unlock()
                }
            }
        }
        let refreshBehavior = RefreshBehavior()

        TrackerURLProtocolStub.handler = { request in
            if request.url.path == "/auth/oauth2/token" {
                let status = refreshBehavior.statusCode
                if status != 200 {
                    return .http(status: status, data: Data(#"{"error":"refresh_failed"}"#.utf8))
                }
                // Omit refresh_token in response to ensure existing refresh token is preserved.
                let body = """
                { "access_token": "fresh-access", "token_type": "Bearer", "expires_in": 3600 }
                """
                return .http(status: 200, data: Data(body.utf8))
            }

            if request.url.path == "/v1/my/library/400" {
                return .http(status: 400, data: Data(#"{"status":400,"message":"Bad request"}"#.utf8))
            }

            if request.url.path == "/v1/my/library/403" {
                return .http(status: 403, data: Data(#"{"status":403,"message":"Forbidden"}"#.utf8))
            }

            if request.url.path == "/v1/my/library/10" || request.url.path == "/v1/my/library/11" {
                let seriesId = request.url.lastPathComponent
                if request.header("Authorization") == "Bearer fresh-access" {
                    let body = """
                    {"status":200,"data":{"id":1,"series_id":\(seriesId),"state":"reading","progress_chapter":5}}
                    """
                    return .http(status: 200, data: Data(body.utf8))
                }
                return .http(status: 401, data: Data(#"{"status":401,"message":"Expired"}"#.utf8))
            }

            return .http(status: 404, data: Data())
        }

        // HTTP 400 and 403 must NOT trigger OAuth refresh.
        await #expect(throws: MangaBakaApiError.apiError(message: "Bad request")) {
            try await env.api.getLibraryEntry(seriesId: 400)
        }
        await #expect(throws: MangaBakaApiError.unauthorized(message: "Forbidden")) {
            try await env.api.getLibraryEntry(seriesId: 403)
        }
        #expect(!TrackerURLProtocolStub.recordedRequests.contains { $0.url.path == "/auth/oauth2/token" })

        // Concurrent 401s coalesce into a single refresh request and succeed.
        async let first = env.api.getLibraryEntry(seriesId: 10)
        async let second = env.api.getLibraryEntry(seriesId: 11)
        let (entry1, entry2) = try await (first, second)
        #expect(entry1.progressChapter == 5)
        #expect(entry2.progressChapter == 5)

        let refreshRequests = TrackerURLProtocolStub.recordedRequests.filter { $0.url.path == "/auth/oauth2/token" }
        #expect(refreshRequests.count == 1)
        let refreshRequest = try #require(refreshRequests.first)
        let rawBody = String(data: refreshRequest.body ?? Data(), encoding: .utf8) ?? ""
        #expect(rawBody.contains("refresh_token=ref%2Bwith%2Fspecial%3Dchars"))
        #expect(refreshRequest.header("Content-Type") == "application/x-www-form-urlencoded")
        #expect(await env.api.oauth.tokens?.refreshToken == "ref+with/special=chars")
        #expect(await env.api.oauth.tokens?.accessToken == "fresh-access")

        // Transient 500, and permanent 400 / 401 refresh failures must all preserve existing OAuth tokens.
        for failureStatus in [500, 400, 401] {
            TrackerURLProtocolStub.clearRecordedRequests()
            refreshBehavior.statusCode = failureStatus
            await env.api.oauth.setTokens(initialOAuth)
            await #expect(throws: MangaBakaApiError.unauthorized(message: "Expired")) {
                try await env.api.getLibraryEntry(seriesId: 10)
            }
            #expect(await env.api.oauth.tokens?.refreshToken == "ref+with/special=chars")
            #expect(await env.api.oauth.tokens?.accessToken == "expired-access")
            #expect(await env.api.oauth.tokens?.askedForRefresh == (failureStatus != 500))
        }
    }

    @Test func removeApiKeyPreservesOAuthAndLogoutRemovesDefaultsCleanly() async throws {
        let env = makeTestEnvironment()
        defer { env.restoreDefaults() }

        let oauth = OAuthResponse(
            tokenType: "Bearer",
            refreshToken: "keep-refresh",
            accessToken: "keep-access",
            expiresIn: 3600,
            askedForRefresh: false
        )
        await env.api.oauth.setTokens(oauth)
        UserDefaults.standard.set("keep-access", forKey: "Tracker.mangabaka.token")

        TrackerURLProtocolStub.handler = { request in
            if request.url.path == "/v1/my/profile" {
                let body = """
                { "status": 200, "data": { "id": "u1", "preferred_username": "sfai05", "auth_type": "pat", "scopes": [] } }
                """
                return .http(status: 200, data: Data(body.utf8))
            }
            return .http(status: 404, data: Data())
        }

        _ = try await env.tracker.saveApiKey("mb-pat")
        #expect(env.tracker.isUsingApiKey)
        #expect(env.tracker.isLoggedIn)

        env.tracker.removeApiKey()
        #expect(!env.tracker.isUsingApiKey)
        #expect(env.authStore.cachedUsername == nil)
        #expect(env.tracker.isLoggedIn)
        #expect(await env.api.oauth.tokens?.accessToken == "keep-access")

        await env.tracker.logout()
        #expect(!env.tracker.isUsingApiKey)
        #expect(!env.tracker.isLoggedIn)
        #expect(await env.api.oauth.tokens == nil)
        #expect(UserDefaults.standard.data(forKey: "Tracker.mangabaka.oauth") == nil)
        #expect(UserDefaults.standard.string(forKey: "Tracker.mangabaka.token") == nil)
    }
}

private enum StubKeychainError: Error, Equatable {
    case readFailed
    case writeFailed
}

private final class StubKeychainStore: SyncKeychainStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    var readFailuresRemaining = 0
    var writeError: Error?

    func readData(account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if readFailuresRemaining > 0 {
            readFailuresRemaining -= 1
            throw StubKeychainError.readFailed
        }
        return storage[account]
    }

    func writeData(_ data: Data, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let writeError {
            throw writeError
        }
        storage[account] = data
    }

    func delete(account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: account)
    }
}

private struct RecordedRequest: Sendable {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: Data?

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

private enum StubResponse: Sendable {
    case http(status: Int, data: Data)
    case failure(URLError.Code)
}

private final class TrackerURLProtocolStub: URLProtocol {
    private static let lock = NSLock()
    private static var _handler: (@Sendable (RecordedRequest) -> StubResponse)?
    private static var _recordedRequests: [RecordedRequest] = []

    static var handler: (@Sendable (RecordedRequest) -> StubResponse)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _handler
        }
        set {
            lock.lock()
            _handler = newValue
            lock.unlock()
        }
    }

    static var recordedRequests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _recordedRequests
    }

    static func clearRecordedRequests() {
        lock.lock()
        _recordedRequests = []
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        _handler = nil
        _recordedRequests = []
        lock.unlock()
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let recorded = RecordedRequest(
            method: request.httpMethod ?? "GET",
            url: url,
            headers: request.allHTTPHeaderFields ?? [:],
            body: readStreamBody(from: request)
        )

        Self.lock.lock()
        Self._recordedRequests.append(recorded)
        let handler = Self._handler
        Self.lock.unlock()

        let outcome = handler?(recorded) ?? .http(status: 500, data: Data())
        switch outcome {
            case let .failure(code):
                client?.urlProtocol(self, didFailWithError: URLError(code))
            case let .http(status, data):
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private func readStreamBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data.isEmpty ? nil : data
    }
}
