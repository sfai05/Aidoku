//
//  MangaBakaModels.swift
//  Aidoku
//
//  Created by Skitty on 2/24/26.
//

import AidokuRunner
import Foundation

struct MangaBakaResponse<T: Decodable>: Decodable {
    let status: Int
    let message: String?
    let data: T?
    let issues: [MangaBakaIssue]?
}

struct MangaBakaIssue: Decodable {
    let code: String
    let message: String?
}

enum MangaBakaStatus: String, Decodable {
    case cancelled
    case completed
    case hiatus
    case releasing
    case unknown
    case upcoming

    func into() -> PublishingStatus {
        switch self {
            case .cancelled: .cancelled
            case .completed: .completed
            case .hiatus: .hiatus
            case .releasing: .ongoing
            case .unknown: .unknown
            case .upcoming: .notPublished
        }
    }

    // MARK: - Fork: AidokuRunner status conversion for metadata pull
    func toRunnerStatus() -> AidokuRunner.PublishingStatus {
        switch self {
            case .cancelled: .cancelled
            case .completed: .completed
            case .hiatus: .hiatus
            case .releasing: .ongoing
            case .unknown, .upcoming: .unknown
        }
    }
}

enum MangaBakaType: String, Decodable {
    case manga
    case novel
    case manhwa
    case manhua
    case oel
    case other

    func into() -> MediaType {
        switch self {
            case .manga: .manga
            case .novel: .novel
            case .manhwa: .manhwa
            case .manhua: .manhua
            case .oel: .oel
            case .other: .unknown
        }
    }
}

enum MangaBakaContentRating: String, Decodable {
    case safe
    case suggestive
    case erotica
    case pornographic
}

// MARK: - Fork: Extended series metadata for tracker metadata pull
private struct AnyDecodableSkip: Decodable {
    init(from decoder: Decoder) throws {}
}

private struct LossyDecodableArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var decoded: [Element] = []
        while !container.isAtEnd {
            if (try? container.decodeNil()) == true {
                continue
            }
            if let value = try? container.decode(Element.self) {
                decoded.append(value)
            } else if (try? container.decode(AnyDecodableSkip.self)) == nil {
                break
            }
        }
        self.elements = decoded
    }
}

struct MangaBakaTitle: Decodable, Equatable, Sendable {
    let language: String?
    let title: String
    let isPrimary: Bool?
    let traits: [String]?
    let note: String?

    enum CodingKeys: String, CodingKey {
        case language
        case title
        case isPrimary = "is_primary"
        case traits
        case note
    }
}

struct FlexibleStringID: Decodable, Equatable, Sendable {
    let value: String

    var intValue: Int? {
        Int(value)
    }

    init(_ value: String) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            self.value = String(intVal)
        } else if let strVal = try? container.decode(String.self) {
            self.value = strVal
        } else if let doubleVal = try? container.decode(Double.self) {
            if doubleVal.rounded() == doubleVal {
                self.value = String(Int(doubleVal))
            } else {
                self.value = String(doubleVal)
            }
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected String or Int identifier"
                )
            )
        }
    }
}

struct MangaBakaPagination: Decodable, Equatable, Sendable {
    let count: Int?
    let page: Int?
    let limit: Int?
    let next: String?
}

struct MangaBakaImageVariant: Decodable, Equatable, Sendable {
    let x1: String?
    let x2: String?
    let x3: String?
}

struct MangaBakaSeriesImage: Decodable, Equatable, Sendable {
    let id: Int
    let index: String?
    let indexNumeric: Double?
    let type: String?
    let language: String?
    let note: String?
    let image: ImageSet

    struct ImageSet: Decodable, Equatable, Sendable {
        let raw: MangaBakaSeries.Cover.Raw
        let x250: MangaBakaImageVariant?
        let x350: MangaBakaImageVariant?
    }

    enum CodingKeys: String, CodingKey {
        case id
        case index
        case indexNumeric = "index_numeric"
        case type
        case language
        case note
        case image
    }

    init(
        id: Int,
        index: String?,
        indexNumeric: Double?,
        type: String?,
        language: String?,
        note: String?,
        image: ImageSet
    ) {
        self.id = id
        self.index = index
        self.indexNumeric = indexNumeric
        self.type = type
        self.language = language
        self.note = note
        self.image = image
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(Int.self, forKey: .id)
        self.index = (try? container.decodeIfPresent(FlexibleStringID.self, forKey: .index))?.value
        self.indexNumeric = try? container.decodeIfPresent(Double.self, forKey: .indexNumeric)
        self.type = try? container.decodeIfPresent(String.self, forKey: .type)
        self.language = try? container.decodeIfPresent(String.self, forKey: .language)
        self.note = try? container.decodeIfPresent(String.self, forKey: .note)
        self.image = try container.decode(ImageSet.self, forKey: .image)
    }
}

struct MangaBakaImagesResponse: Decodable, Sendable {
    let status: Int
    let message: String?
    let data: [MangaBakaSeriesImage]?
    let pagination: MangaBakaPagination?
    let availableLanguages: [String]?
    let availableTypes: [String]?

    enum CodingKeys: String, CodingKey {
        case status
        case message
        case data
        case pagination
        case availableLanguages = "available_languages"
        case availableTypes = "available_types"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.status = try container.decode(Int.self, forKey: .status)
        self.message = try? container.decodeIfPresent(String.self, forKey: .message)
        self.data = (try? container.decodeIfPresent(LossyDecodableArray<MangaBakaSeriesImage>.self, forKey: .data))?.elements
        self.pagination = try? container.decodeIfPresent(MangaBakaPagination.self, forKey: .pagination)
        self.availableLanguages = (try? container.decodeIfPresent(LossyDecodableArray<String>.self, forKey: .availableLanguages))?.elements
        self.availableTypes = (try? container.decodeIfPresent(LossyDecodableArray<String>.self, forKey: .availableTypes))?.elements
    }
}

struct MangaBakaSeriesImagesResult: Equatable, Sendable {
    let images: [MangaBakaSeriesImage]
    let pagination: MangaBakaPagination?
    let availableLanguages: [String]
    let availableTypes: [String]
}

struct MangaBakaSeries: Decodable, Sendable {
    let id: Int
    let title: String
    let cover: Cover
    let description: String?
    let status: MangaBakaStatus
    let type: MangaBakaType

    let totalChapters: String?
    let finalVolume: String?

    // Fork: Extended metadata fields for metadata pull
    let originalLanguage: String?
    let nativeTitle: String?
    let romanizedTitle: String?
    let titles: [MangaBakaTitle]?
    let authors: [String]?
    let artists: [String]?
    let genres: [String]?
    let source: SourceLinks?

    struct Cover: Decodable, Equatable, Sendable {
        struct Raw: Decodable, Equatable, Sendable {
            let url: String?
        }
        let raw: Raw
    }

    struct SourceLinks: Decodable, Equatable, Sendable {
        struct Entry: Decodable, Equatable, Sendable {
            let id: FlexibleStringID?
        }

        let anilist: Entry?
        let myAnimeList: Entry?
        let kitsu: Entry?
        let mangaUpdates: Entry?

        enum CodingKeys: String, CodingKey {
            case anilist
            case myAnimeList = "my_anime_list"
            case kitsu
            case mangaUpdates = "manga_updates"
        }

        init(
            anilist: Entry? = nil,
            myAnimeList: Entry? = nil,
            kitsu: Entry? = nil,
            mangaUpdates: Entry? = nil
        ) {
            self.anilist = anilist
            self.myAnimeList = myAnimeList
            self.kitsu = kitsu
            self.mangaUpdates = mangaUpdates
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.anilist = try? container.decodeIfPresent(Entry.self, forKey: .anilist)
            self.myAnimeList = try? container.decodeIfPresent(Entry.self, forKey: .myAnimeList)
            self.kitsu = try? container.decodeIfPresent(Entry.self, forKey: .kitsu)
            self.mangaUpdates = try? container.decodeIfPresent(Entry.self, forKey: .mangaUpdates)
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case cover
        case description
        case status
        case type
        case totalChapters = "total_chapters"
        case finalVolume = "final_volume"
        case originalLanguage = "original_language"
        case nativeTitle = "native_title"
        case romanizedTitle = "romanized_title"
        case titles
        case authors
        case artists
        case genres
        case source
    }

    // Fork: Leniently decode extended metadata fields so unexpected API payloads never break tracker search/sync
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(Int.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.cover = try container.decode(Cover.self, forKey: .cover)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.status = try container.decode(MangaBakaStatus.self, forKey: .status)
        self.type = try container.decode(MangaBakaType.self, forKey: .type)
        self.totalChapters = try container.decodeIfPresent(String.self, forKey: .totalChapters)
        self.finalVolume = try container.decodeIfPresent(String.self, forKey: .finalVolume)

        self.originalLanguage = try? container.decodeIfPresent(String.self, forKey: .originalLanguage)
        self.nativeTitle = try? container.decodeIfPresent(String.self, forKey: .nativeTitle)
        self.romanizedTitle = try? container.decodeIfPresent(String.self, forKey: .romanizedTitle)
        self.titles = (try? container.decodeIfPresent(LossyDecodableArray<MangaBakaTitle>.self, forKey: .titles))?.elements
        self.authors = (try? container.decodeIfPresent(LossyDecodableArray<String>.self, forKey: .authors))?.elements
        self.artists = (try? container.decodeIfPresent(LossyDecodableArray<String>.self, forKey: .artists))?.elements
        self.genres = (try? container.decodeIfPresent(LossyDecodableArray<String>.self, forKey: .genres))?.elements
        self.source = try? container.decodeIfPresent(SourceLinks.self, forKey: .source)
    }
}

enum MangaBakaLibraryState: String, Codable {
    case considering
    case planToRead = "plan_to_read"
    case reading
    case completed
    case rereading
    case paused
    case dropped

    init(_ status: TrackStatus) {
        switch status {
            case .planning: self = .planToRead
            case .reading: self = .reading
            case .completed: self = .completed
            case .rereading: self = .rereading
            case .paused: self = .paused
            case .dropped: self = .dropped
            default: self = .reading
        }
    }

    func into() -> TrackStatus {
        switch self {
            case .considering: .planning
            case .planToRead: .planning
            case .reading: .reading
            case .completed: .completed
            case .rereading: .rereading
            case .paused: .paused
            case .dropped: .dropped
        }
    }
}

struct MangaBakaLibraryEntry: Codable {
    var id: Int?
    var seriesId: Int?
    var state: MangaBakaLibraryState?
    var rating: Int?
    var progressChapter: Int?
    var progressVolume: Int?
    var startDate: String?
    var finishDate: String?

    enum CodingKeys: String, CodingKey {
        case id
        case seriesId = "series_id"
        case state
        case rating
        case progressChapter = "progress_chapter"
        case progressVolume = "progress_volume"
        case startDate = "start_date"
        case finishDate = "finish_date"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.id, forKey: .id)
        try container.encodeIfPresent(self.seriesId, forKey: .seriesId)
        try container.encodeIfPresent(self.state, forKey: .state)
        try container.encodeIfPresent(self.rating, forKey: .rating)
        try container.encodeIfPresent(self.progressChapter, forKey: .progressChapter)
        try container.encodeIfPresent(self.progressVolume, forKey: .progressVolume)
        if let startDate {
            if startDate.hasPrefix("1969-12-31") || startDate.hasPrefix("1970-01-01") {
                try container.encodeNil(forKey: .startDate)
            } else {
                try container.encode(startDate, forKey: .startDate)
            }
        }
        if let finishDate {
            if finishDate.hasPrefix("1969-12-31") || finishDate.hasPrefix("1970-01-01") {
                try container.encodeNil(forKey: .startDate)
            } else {
                try container.encode(finishDate, forKey: .startDate)
            }
        }
    }
}
