//
//  SyncTestFixtures.swift
//  AidokuTests
//

@testable import Aidoku
import Foundation

enum SyncTestFixtures {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    private static func convert<Source: Encodable, Target: Decodable>(_ source: Source) -> Target {
        do {
            let data = try encoder.encode(source)
            return try decoder.decode(Target.self, from: data)
        } catch {
            fatalError("Failed to construct sync test fixture \(Target.self): \(error)")
        }
    }

    static func date(_ secondsSinceEpoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: secondsSinceEpoch)
    }

    static func makeLibraryManga(
        sourceId: String = "mangadex",
        mangaId: String = "m1",
        dateAdded: Date = Date(timeIntervalSince1970: 1_000),
        lastOpened: Date = Date(timeIntervalSince1970: 1_000),
        lastUpdated: Date = Date(timeIntervalSince1970: 1_000),
        lastUpdatedChapters: Date? = Date(timeIntervalSince1970: 1_000),
        lastChapter: Date? = nil,
        lastRead: Date? = nil,
        categories: [String]? = []
    ) -> BackupLibraryManga {
        struct Wire: Encodable {
            let lastOpened: Date
            let lastUpdated: Date
            let lastUpdatedChapters: Date?
            let lastChapter: Date?
            let lastRead: Date?
            let dateAdded: Date
            let categories: [String]?
            let mangaId: String
            let sourceId: String
        }
        return convert(
            Wire(
                lastOpened: lastOpened,
                lastUpdated: lastUpdated,
                lastUpdatedChapters: lastUpdatedChapters,
                lastChapter: lastChapter,
                lastRead: lastRead,
                dateAdded: dateAdded,
                categories: categories,
                mangaId: mangaId,
                sourceId: sourceId
            )
        )
    }

    static func makeManga(
        sourceId: String = "mangadex",
        id: String = "m1",
        title: String = "Sample Manga",
        author: String? = "Author",
        artist: String? = "Artist",
        desc: String? = "Description",
        tags: [String]? = ["Action"],
        cover: String? = "https://example.com/cover.jpg",
        url: String? = "https://example.com/manga/1",
        status: Int = 1,
        nsfw: Int = 0,
        viewer: Int = 1,
        neverUpdate: Bool? = false,
        nextUpdateTime: Date? = nil,
        chapterFlags: Int? = 0,
        langFilter: String? = nil,
        scanlatorFilter: [String]? = nil,
        editedKeys: Int? = nil
    ) -> BackupManga {
        struct Wire: Encodable {
            let id: String
            let sourceId: String
            let title: String
            let author: String?
            let artist: String?
            let desc: String?
            let tags: [String]?
            let cover: String?
            let url: String?
            let status: Int
            let nsfw: Int
            let viewer: Int
            let neverUpdate: Bool?
            let nextUpdateTime: Date?
            let chapterFlags: Int?
            let langFilter: String?
            let scanlatorFilter: [String]?
            let editedKeys: Int?
        }
        return convert(
            Wire(
                id: id,
                sourceId: sourceId,
                title: title,
                author: author,
                artist: artist,
                desc: desc,
                tags: tags,
                cover: cover,
                url: url,
                status: status,
                nsfw: nsfw,
                viewer: viewer,
                neverUpdate: neverUpdate,
                nextUpdateTime: nextUpdateTime,
                chapterFlags: chapterFlags,
                langFilter: langFilter,
                scanlatorFilter: scanlatorFilter,
                editedKeys: editedKeys
            )
        )
    }

    static func makeHistory(
        sourceId: String = "mangadex",
        mangaId: String = "m1",
        chapterId: String = "c1",
        dateRead: Date = Date(timeIntervalSince1970: 2_000),
        progress: Int? = 5,
        total: Int? = 20,
        completed: Bool = false
    ) -> BackupHistory {
        struct Wire: Encodable {
            let dateRead: Date
            let sourceId: String
            let chapterId: String
            let mangaId: String
            let progress: Int?
            let total: Int?
            let completed: Bool
        }
        return convert(
            Wire(
                dateRead: dateRead,
                sourceId: sourceId,
                chapterId: chapterId,
                mangaId: mangaId,
                progress: progress,
                total: total,
                completed: completed
            )
        )
    }

    static func makeChapter(
        sourceId: String = "mangadex",
        mangaId: String = "m1",
        id: String = "c1",
        title: String? = "Chapter 1",
        scanlator: String? = nil,
        url: String? = nil,
        lang: String = "en",
        chapter: Float? = 1,
        volume: Float? = nil,
        dateUploaded: Date? = nil,
        thumbnail: String? = nil,
        locked: Bool? = false,
        sourceOrder: Int = 0
    ) -> BackupChapter {
        struct Wire: Encodable {
            let sourceId: String
            let mangaId: String
            let id: String
            let title: String?
            let scanlator: String?
            let url: String?
            let lang: String
            let chapter: Float?
            let volume: Float?
            let dateUploaded: Date?
            let thumbnail: String?
            let locked: Bool?
            let sourceOrder: Int
        }
        return convert(
            Wire(
                sourceId: sourceId,
                mangaId: mangaId,
                id: id,
                title: title,
                scanlator: scanlator,
                url: url,
                lang: lang,
                chapter: chapter,
                volume: volume,
                dateUploaded: dateUploaded,
                thumbnail: thumbnail,
                locked: locked,
                sourceOrder: sourceOrder
            )
        )
    }

    static func makeCategory(
        title: String,
        sort: Int? = 0,
        group: Bool? = false,
        data: Data? = nil
    ) -> BackupCategory {
        struct Wire: Encodable {
            let title: String
            let sort: Int?
            let group: Bool?
            let data: Data?
        }
        return convert(Wire(title: title, sort: sort, group: group, data: data))
    }

    static func makeTrackItem(
        id: String = "101",
        trackerId: String = "anilist",
        sourceId: String = "mangadex",
        mangaId: String = "m1",
        title: String? = "Sample",
        chapterOffset: Int? = 0
    ) -> BackupTrackItem {
        struct Wire: Encodable {
            let id: String
            let trackerId: String
            let mangaId: String
            let sourceId: String
            let title: String?
            let chapterOffset: Int?
        }
        return convert(
            Wire(
                id: id,
                trackerId: trackerId,
                mangaId: mangaId,
                sourceId: sourceId,
                title: title,
                chapterOffset: chapterOffset
            )
        )
    }

    static func makeSession(
        sourceId: String = "mangadex",
        mangaId: String = "m1",
        chapterId: String = "c1",
        pagesRead: Int = 12,
        startDate: Date = Date(timeIntervalSince1970: 2_000),
        endDate: Date = Date(timeIntervalSince1970: 2_120)
    ) -> BackupReadingSession {
        struct Wire: Encodable {
            let pagesRead: Int
            let startDate: Date
            let endDate: Date
            let sourceId: String
            let mangaId: String
            let chapterId: String
        }
        return convert(
            Wire(
                pagesRead: pagesRead,
                startDate: startDate,
                endDate: endDate,
                sourceId: sourceId,
                mangaId: mangaId,
                chapterId: chapterId
            )
        )
    }

    static func makeUpdate(
        sourceId: String = "mangadex",
        mangaId: String = "m1",
        chapterId: String = "c1",
        date: Date = Date(timeIntervalSince1970: 2_000),
        viewed: Bool = false
    ) -> BackupUpdate {
        struct Wire: Encodable {
            let date: Date
            let viewed: Bool
            let sourceId: String
            let mangaId: String
            let chapterId: String
        }
        return convert(Wire(date: date, viewed: viewed, sourceId: sourceId, mangaId: mangaId, chapterId: chapterId))
    }

    static func makeVocab(
        sourceId: String = "mangadex",
        mangaId: String = "m1",
        chapterId: String = "c1",
        word: String = "漫画",
        reading: String? = "まんが",
        sentence: String? = nil,
        clozeOffset: Int? = 0,
        clozeText: String? = nil,
        page: Int = 3,
        createdDate: Date = Date(timeIntervalSince1970: 2_000)
    ) -> BackupVocabEntry {
        struct Wire: Encodable {
            let sourceId: String
            let mangaId: String
            let chapterId: String
            let word: String
            let reading: String?
            let sentence: String?
            let clozeOffset: Int?
            let clozeText: String?
            let page: Int
            let createdDate: Date
        }
        return convert(
            Wire(
                sourceId: sourceId,
                mangaId: mangaId,
                chapterId: chapterId,
                word: word,
                reading: reading,
                sentence: sentence,
                clozeOffset: clozeOffset,
                clozeText: clozeText,
                page: page,
                createdDate: createdDate
            )
        )
    }

    static func makeSource(id: String, apiVersion: String? = nil, config: Data? = nil) -> BackupSource {
        if let config {
            struct Wire: Encodable {
                let id: String
                let apiVersion: String?
                let config: Data?
            }
            return convert(Wire(id: id, apiVersion: apiVersion, config: config))
        } else {
            return convert(id)
        }
    }

    static func makeBackup(
        library: [BackupLibraryManga] = [],
        history: [BackupHistory] = [],
        manga: [BackupManga] = [],
        chapters: [BackupChapter] = [],
        trackItems: [BackupTrackItem] = [],
        readingSessions: [BackupReadingSession] = [],
        vocabulary: [BackupVocabEntry] = [],
        updates: [BackupUpdate] = [],
        categories: [BackupCategory] = [],
        sources: [BackupSource] = [],
        sourceLists: [String] = [],
        settings: [String: JSONAnyValue]? = nil,
        date: Date = Date(timeIntervalSince1970: 5_000),
        version: String? = "0.7.1"
    ) -> Backup {
        Backup(
            library: library,
            history: history,
            manga: manga,
            chapters: chapters,
            trackItems: trackItems,
            readingSessions: readingSessions,
            vocabulary: vocabulary,
            updates: updates,
            categories: categories,
            sources: sources,
            sourceLists: sourceLists,
            settings: settings,
            date: date,
            name: nil,
            automatic: true,
            version: version
        )
    }
}
