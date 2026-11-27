//
//  SyncModels.swift
//  Aidoku
//

import Foundation

struct SyncMangaTombstone: Codable, Hashable, Sendable {
    var sourceId: String
    var mangaId: String
    var deletedAt: Date

    var mangaIdentifier: MangaIdentifier {
        .init(sourceKey: sourceId, mangaKey: mangaId)
    }

    init(sourceId: String, mangaId: String, deletedAt: Date) {
        self.sourceId = sourceId
        self.mangaId = mangaId
        self.deletedAt = deletedAt
    }

    init(mangaId: MangaIdentifier, deletedAt: Date) {
        self.sourceId = mangaId.sourceKey
        self.mangaId = mangaId.mangaKey
        self.deletedAt = deletedAt
    }
}

struct SyncHistoryTombstone: Codable, Hashable, Sendable {
    var sourceId: String
    var mangaId: String
    var chapterId: String
    var deletedAt: Date

    var chapterIdentifier: ChapterIdentifier {
        .init(sourceKey: sourceId, mangaKey: mangaId, chapterKey: chapterId)
    }

    init(sourceId: String, mangaId: String, chapterId: String, deletedAt: Date) {
        self.sourceId = sourceId
        self.mangaId = mangaId
        self.chapterId = chapterId
        self.deletedAt = deletedAt
    }

    init(chapterId: ChapterIdentifier, deletedAt: Date) {
        self.sourceId = chapterId.sourceKey
        self.mangaId = chapterId.mangaKey
        self.chapterId = chapterId.chapterKey
        self.deletedAt = deletedAt
    }
}

struct SyncCategoryTombstone: Codable, Hashable, Sendable {
    var title: String
    var deletedAt: Date
}

struct SyncTrackKey: Codable, Hashable, Sendable {
    var trackerId: String
    var sourceId: String
    var mangaId: String

    init(trackerId: String, sourceId: String, mangaId: String) {
        self.trackerId = trackerId
        self.sourceId = sourceId
        self.mangaId = mangaId
    }

    init(trackerId: String, mangaId: MangaIdentifier) {
        self.trackerId = trackerId
        self.sourceId = mangaId.sourceKey
        self.mangaId = mangaId.mangaKey
    }

    init(trackItem: BackupTrackItem) {
        self.trackerId = trackItem.trackerId
        self.sourceId = trackItem.sourceId
        self.mangaId = trackItem.mangaId
    }
}

struct SyncTrackTombstone: Codable, Hashable, Sendable {
    var trackerId: String
    var sourceId: String
    var mangaId: String
    var deletedAt: Date

    var trackKey: SyncTrackKey {
        .init(trackerId: trackerId, sourceId: sourceId, mangaId: mangaId)
    }

    init(trackerId: String, sourceId: String, mangaId: String, deletedAt: Date) {
        self.trackerId = trackerId
        self.sourceId = sourceId
        self.mangaId = mangaId
        self.deletedAt = deletedAt
    }

    init(trackKey: SyncTrackKey, deletedAt: Date) {
        self.trackerId = trackKey.trackerId
        self.sourceId = trackKey.sourceId
        self.mangaId = trackKey.mangaId
        self.deletedAt = deletedAt
    }
}

struct SyncCategoryUpsert: Codable, Hashable, Sendable {
    var title: String
    var updatedAt: Date
}

struct SyncTrackUpsert: Codable, Hashable, Sendable {
    var trackerId: String
    var sourceId: String
    var mangaId: String
    var updatedAt: Date

    var trackKey: SyncTrackKey {
        .init(trackerId: trackerId, sourceId: sourceId, mangaId: mangaId)
    }

    init(trackerId: String, sourceId: String, mangaId: String, updatedAt: Date) {
        self.trackerId = trackerId
        self.sourceId = sourceId
        self.mangaId = mangaId
        self.updatedAt = updatedAt
    }

    init(trackKey: SyncTrackKey, updatedAt: Date) {
        self.trackerId = trackKey.trackerId
        self.sourceId = trackKey.sourceId
        self.mangaId = trackKey.mangaId
        self.updatedAt = updatedAt
    }
}

struct SyncMangaCategoryUpdate: Codable, Hashable, Sendable {
    var sourceId: String
    var mangaId: String
    var updatedAt: Date

    var mangaIdentifier: MangaIdentifier {
        .init(sourceKey: sourceId, mangaKey: mangaId)
    }

    init(sourceId: String, mangaId: String, updatedAt: Date) {
        self.sourceId = sourceId
        self.mangaId = mangaId
        self.updatedAt = updatedAt
    }

    init(mangaId: MangaIdentifier, updatedAt: Date) {
        self.sourceId = mangaId.sourceKey
        self.mangaId = mangaId.mangaKey
        self.updatedAt = updatedAt
    }
}

struct SyncTombstones: Codable, Equatable, Sendable {
    var libraryManga: [SyncMangaTombstone]
    var history: [SyncHistoryTombstone]
    var mangaHistory: [SyncMangaTombstone]
    var categories: [SyncCategoryTombstone]
    var tracks: [SyncTrackTombstone]
    var categoryUpserts: [SyncCategoryUpsert]
    var trackUpserts: [SyncTrackUpsert]
    var mangaCategoryUpdates: [SyncMangaCategoryUpdate]

    static let empty = SyncTombstones(
        libraryManga: [],
        history: [],
        mangaHistory: [],
        categories: [],
        tracks: [],
        categoryUpserts: [],
        trackUpserts: [],
        mangaCategoryUpdates: []
    )

    init(
        libraryManga: [SyncMangaTombstone] = [],
        history: [SyncHistoryTombstone] = [],
        mangaHistory: [SyncMangaTombstone] = [],
        categories: [SyncCategoryTombstone] = [],
        tracks: [SyncTrackTombstone] = [],
        categoryUpserts: [SyncCategoryUpsert] = [],
        trackUpserts: [SyncTrackUpsert] = [],
        mangaCategoryUpdates: [SyncMangaCategoryUpdate] = []
    ) {
        self.libraryManga = libraryManga
        self.history = history
        self.mangaHistory = mangaHistory
        self.categories = categories
        self.tracks = tracks
        self.categoryUpserts = categoryUpserts
        self.trackUpserts = trackUpserts
        self.mangaCategoryUpdates = mangaCategoryUpdates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        libraryManga = try container.decodeIfPresent([SyncMangaTombstone].self, forKey: .libraryManga) ?? []
        history = try container.decodeIfPresent([SyncHistoryTombstone].self, forKey: .history) ?? []
        mangaHistory = try container.decodeIfPresent([SyncMangaTombstone].self, forKey: .mangaHistory) ?? []
        categories = try container.decodeIfPresent([SyncCategoryTombstone].self, forKey: .categories) ?? []
        tracks = try container.decodeIfPresent([SyncTrackTombstone].self, forKey: .tracks) ?? []
        categoryUpserts = try container.decodeIfPresent([SyncCategoryUpsert].self, forKey: .categoryUpserts) ?? []
        trackUpserts = try container.decodeIfPresent([SyncTrackUpsert].self, forKey: .trackUpserts) ?? []
        mangaCategoryUpdates = try container.decodeIfPresent([SyncMangaCategoryUpdate].self, forKey: .mangaCategoryUpdates) ?? []
    }

    var isEmpty: Bool {
        libraryManga.isEmpty
            && history.isEmpty
            && mangaHistory.isEmpty
            && categories.isEmpty
            && tracks.isEmpty
            && categoryUpserts.isEmpty
            && trackUpserts.isEmpty
            && mangaCategoryUpdates.isEmpty
    }

    func canonicalized() -> SyncTombstones {
        SyncTombstones(
            libraryManga: Self.deduplicatedMaxDate(libraryManga, key: \.mangaIdentifier, date: \.deletedAt)
                .sorted { ($0.sourceId, $0.mangaId) < ($1.sourceId, $1.mangaId) },
            history: Self.deduplicatedMaxDate(history, key: \.chapterIdentifier, date: \.deletedAt)
                .sorted { ($0.sourceId, $0.mangaId, $0.chapterId) < ($1.sourceId, $1.mangaId, $1.chapterId) },
            mangaHistory: Self.deduplicatedMaxDate(mangaHistory, key: \.mangaIdentifier, date: \.deletedAt)
                .sorted { ($0.sourceId, $0.mangaId) < ($1.sourceId, $1.mangaId) },
            categories: Self.deduplicatedMaxDate(categories, key: \.title, date: \.deletedAt)
                .sorted { $0.title < $1.title },
            tracks: Self.deduplicatedMaxDate(tracks, key: \.trackKey, date: \.deletedAt)
                .sorted { ($0.trackerId, $0.sourceId, $0.mangaId) < ($1.trackerId, $1.sourceId, $1.mangaId) },
            categoryUpserts: Self.deduplicatedMaxDate(categoryUpserts, key: \.title, date: \.updatedAt)
                .sorted { $0.title < $1.title },
            trackUpserts: Self.deduplicatedMaxDate(trackUpserts, key: \.trackKey, date: \.updatedAt)
                .sorted { ($0.trackerId, $0.sourceId, $0.mangaId) < ($1.trackerId, $1.sourceId, $1.mangaId) },
            mangaCategoryUpdates: Self.deduplicatedMaxDate(mangaCategoryUpdates, key: \.mangaIdentifier, date: \.updatedAt)
                .sorted { ($0.sourceId, $0.mangaId) < ($1.sourceId, $1.mangaId) }
        )
    }

    private static func deduplicatedMaxDate<T, K: Hashable>(
        _ items: [T],
        key: (T) -> K,
        date: (T) -> Date
    ) -> [T] {
        var map: [K: T] = [:]
        for item in items {
            let itemKey = key(item)
            if let existing = map[itemKey], date(existing) >= date(item) {
                continue
            }
            map[itemKey] = item
        }
        return Array(map.values)
    }
}

struct SyncEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let revision: Int
    let deviceId: String
    let deviceName: String
    let updatedAt: Date
    let tombstones: SyncTombstones
    let backup: Backup

    init(
        schemaVersion: Int = SyncEnvelope.currentSchemaVersion,
        revision: Int,
        deviceId: String,
        deviceName: String,
        updatedAt: Date = Date(),
        tombstones: SyncTombstones = .empty,
        backup: Backup
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.updatedAt = updatedAt
        self.tombstones = tombstones
        self.backup = backup
    }
}
