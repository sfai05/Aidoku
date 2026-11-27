//
//  MangaBakaTracker.swift
//  Aidoku
//
//  Created by Skitty on 2/24/26.
//

import AidokuRunner
import Foundation

/// MangaBaka tracker for Aidoku.
final class MangaBakaTracker: OAuthTracker {
    let id = "mangabaka"
    let name = "MangaBaka"
    let icon = PlatformImage(named: "mangabaka")

    let api: MangaBakaApi

    let callbackHost = "mangabaka-auth"
    var oauthClient: OAuthClient { api.oauth }
    var authStore: MangaBakaAuthStore { api.authStore }
    var isUsingApiKey: Bool { authStore.hasApiKey }

    var isLoggedIn: Bool {
        authStore.hasApiKey || token != nil
    }

    init(api: MangaBakaApi = MangaBakaApi()) {
        self.api = api
    }

    func getTrackerInfo() -> TrackerInfo {
        .init(supportedStatuses: TrackStatus.defaultStatuses, scoreType: .hundredPoint)
    }

    func saveApiKey(_ rawKey: String) async throws -> MangaBakaProfile {
        let profile = try await api.verifyApiKey(rawKey)
        try authStore.saveApiKey(rawKey)
        authStore.cachedUsername = profile.displayName
        // Clear any stale OAuth relogin badge while keeping local Core Data tracks untouched.
        await api.oauth.loadTokens()
        if var existing = await api.oauth.tokens, existing.askedForRefresh {
            existing.askedForRefresh = false
            await api.oauth.setTokens(existing)
        }
        return profile
    }

    func removeApiKey() {
        authStore.clearApiKey()
    }

    func logout() async {
        authStore.clearApiKey()
        token = nil
        await api.oauth.setTokens(nil)
        UserDefaults.standard.removeObject(forKey: "Tracker.\(id).oauth")
        UserDefaults.standard.removeObject(forKey: "Tracker.\(id).token")
    }

    func register(trackId: String, highestChapterRead: Float?, earliestReadDate: Date?) async throws -> String? {
        guard let id = Int(trackId) else {
            throw MangaBakaTrackerError.invalidId
        }
        // Set status to reading if an entry doesn't already exist on MangaBaka; rethrow auth/network errors.
        do {
            _ = try await api.getLibraryEntry(seriesId: id)
        } catch MangaBakaApiError.notFound {
            try await api.updateLibraryEntry(seriesId: id, create: true, data: .init(
                state: highestChapterRead != nil ? .reading : .planToRead,
                progressChapter: highestChapterRead.map(MangaBakaAuthHelpers.normalizeChapterNumber),
                startDate: earliestReadDate.map { MangaBakaAuthHelpers.formatDate($0) }
            ))
        }
        return nil
    }

    func update(trackId: String, update: TrackUpdate) async throws {
        guard let id = Int(trackId) else {
            throw MangaBakaTrackerError.invalidId
        }
        let data = MangaBakaLibraryEntry(
            state: update.status.flatMap(MangaBakaLibraryState.init),
            rating: update.score.map(Double.init),
            progressChapter: update.lastReadChapter.map(MangaBakaAuthHelpers.normalizeChapterNumber),
            progressVolume: update.lastReadVolume.map(Double.init),
            startDate: update.startReadDate.map { MangaBakaAuthHelpers.formatDate($0) },
            finishDate: update.finishReadDate.map { MangaBakaAuthHelpers.formatDate($0) }
        )
        do {
            try await api.updateLibraryEntry(seriesId: id, create: false, data: data)
        } catch MangaBakaApiError.notFound {
            var createData = data
            createData.state = data.state ?? .reading
            try await api.updateLibraryEntry(seriesId: id, create: true, data: createData)
        }
    }

    func getState(trackId: String) async throws -> TrackState {
        guard let id = Int(trackId) else {
            throw MangaBakaTrackerError.invalidId
        }
        let series = try await api.getSeries(id: id)
        let libraryEntry: MangaBakaLibraryEntry?
        do {
            libraryEntry = try await api.getLibraryEntry(seriesId: id)
        } catch MangaBakaApiError.notFound {
            libraryEntry = nil
        }
        return TrackState(
            score: libraryEntry?.rating.map { Int($0.rounded()) },
            status: libraryEntry?.state?.into(),
            lastReadChapter: libraryEntry?.progressChapter.map(Float.init),
            lastReadVolume: libraryEntry?.progressVolume.map { Int(floor($0)) },
            totalChapters: series.status == .releasing ? nil : MangaBakaAuthHelpers.parseTotalCount(series.totalChapters),
            totalVolumes: series.status == .releasing ? nil : MangaBakaAuthHelpers.parseTotalCount(series.finalVolume),
            startReadDate: libraryEntry?.startDate.flatMap { MangaBakaAuthHelpers.parseDate($0) },
            finishReadDate: libraryEntry?.finishDate.flatMap { MangaBakaAuthHelpers.parseDate($0) }
        )
    }

    func getUrl(trackId: String) -> URL? {
        URL(string: "https://mangabaka.org/\(trackId)")
    }

    func search(for manga: AidokuRunner.Manga, includeNsfw: Bool) async throws -> [TrackSearchItem] {
        try await search(title: manga.title, includeNsfw: includeNsfw)
    }

    func search(title: String, includeNsfw: Bool) async throws -> [TrackSearchItem] {
        let results = try await api.search(query: title, nsfw: includeNsfw)
        let libraryEntries: [MangaBakaLibraryEntry]
        do {
            libraryEntries = try await api.getLibraryEntries(seriesIds: results.map { $0.id })
        } catch {
            LogManager.logger.error("Failed to fetch library entries (\(id)): \(error)")
            libraryEntries = []
        }
        return results.map { series in
            TrackSearchItem(
                id: String(series.id),
                title: series.title,
                coverUrl: series.cover.raw.url,
                description: series.description,
                status: series.status.into(),
                type: series.type.into(),
                tracked: libraryEntries.contains(where: { $0.seriesId == series.id })
            )
        }
    }

    func getAuthenticationUrl() async -> URL? {
        await api.oauth.getAuthenticationUrl(
            redirectUri: "aidoku://\(callbackHost)",
            extraQueryItems: ["scope": "library.read+library.write+profile+offline_access+openid"]
        )
    }

    func handleAuthenticationCallback(url: URL) async {
        if let authCode = url.queryParameters?["code"] {
            guard let oauth = await api.oauth.getAccessToken(
                authCode: authCode,
                redirectUri: "aidoku://\(callbackHost)"
            ) else {
                return
            }
            token = oauth.accessToken
            UserDefaults.standard.set(try? JSONEncoder().encode(oauth), forKey: "Tracker.\(id).oauth")
            await api.oauth.setTokens(oauth)
            // Switching back to OAuth clears any API Key while preserving existing local tracks.
            authStore.clearApiKey()
        }
    }
}

enum MangaBakaTrackerError: Error {
    case invalidId
}
