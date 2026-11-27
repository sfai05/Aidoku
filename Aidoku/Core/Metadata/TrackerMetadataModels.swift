//
//  TrackerMetadataModels.swift
//  Aidoku
//
//  Created by Kodoku on 11/27/26.
//

import AidokuRunner
import Foundation

/// A localized or alternate title option returned by a tracker metadata provider.
struct TrackerTitleOption: Identifiable, Hashable, Sendable {
    var id: String {
        "\(languageCode.lowercased())|\(title)"
    }

    let languageCode: String
    let title: String
    let isPrimary: Bool
    let traits: [String]
}

/// A localized synopsis candidate fetched from MangaBaka or companion public databases.
struct TrackerDescriptionOption: Identifiable, Hashable, Sendable {
    var id: String {
        "\(languageCode.lowercased())|\(sourceName.lowercased())|\(text)"
    }

    let languageCode: String
    let text: String
    let sourceName: String
}

/// A cover candidate belonging to a tracked series (e.g., main cover or individual volume covers).
struct TrackerCoverOption: Identifiable, Hashable, Sendable {
    let id: String
    let rawUrl: String
    let thumbnailUrl: String
    let volumeLabel: String?
    let type: String
    let languageCode: String
    let isMain: Bool
}

/// Paginated response of available cover options for a tracked series.
struct TrackerCoverPage: Equatable, Sendable {
    let covers: [TrackerCoverOption]
    let totalCount: Int
    let page: Int
    let hasNextPage: Bool
    let availableLanguages: [String]
    let requestedType: String?

    init(
        covers: [TrackerCoverOption],
        totalCount: Int,
        page: Int,
        hasNextPage: Bool,
        availableLanguages: [String] = [],
        requestedType: String? = nil
    ) {
        self.covers = covers
        self.totalCount = totalCount
        self.page = page
        self.hasNextPage = hasNextPage
        self.availableLanguages = availableLanguages
        self.requestedType = requestedType
    }
}

/// Normalized metadata snapshot pulled from an external tracker series entry.
struct TrackerMangaMetadata: Identifiable, Equatable, Sendable {
    var id: String {
        "\(trackerId):\(trackId)"
    }

    let trackerId: String
    let trackerName: String
    let trackId: String
    let defaultTitle: String
    let titleOptions: [TrackerTitleOption]
    let coverUrl: String?
    let coverOptions: [TrackerCoverOption]
    let availableCoverLanguages: [String]
    let initialCoverFilterType: String?
    let hasLoadedInitialCovers: Bool
    let totalCoverCount: Int
    let hasMoreCovers: Bool
    let authors: [String]
    let nativeAuthors: [String]
    let artists: [String]
    let nativeArtists: [String]
    let status: AidokuRunner.PublishingStatus?
    let contentRating: AidokuRunner.ContentRating?
    let description: String?
    let descriptionOptions: [TrackerDescriptionOption]
    let tags: [String]

    init(
        trackerId: String,
        trackerName: String,
        trackId: String,
        defaultTitle: String,
        titleOptions: [TrackerTitleOption],
        coverUrl: String?,
        coverOptions: [TrackerCoverOption] = [],
        availableCoverLanguages: [String] = [],
        initialCoverFilterType: String? = nil,
        hasLoadedInitialCovers: Bool = true,
        totalCoverCount: Int = 0,
        hasMoreCovers: Bool = false,
        authors: [String],
        nativeAuthors: [String] = [],
        artists: [String],
        nativeArtists: [String] = [],
        status: AidokuRunner.PublishingStatus?,
        contentRating: AidokuRunner.ContentRating? = nil,
        description: String?,
        descriptionOptions: [TrackerDescriptionOption] = [],
        tags: [String]
    ) {
        self.trackerId = trackerId
        self.trackerName = trackerName
        self.trackId = trackId
        self.defaultTitle = defaultTitle
        self.titleOptions = titleOptions
        self.coverUrl = coverUrl
        self.coverOptions = coverOptions
        self.availableCoverLanguages = availableCoverLanguages
        self.initialCoverFilterType = initialCoverFilterType
        self.hasLoadedInitialCovers = hasLoadedInitialCovers
        self.totalCoverCount = totalCoverCount
        self.hasMoreCovers = hasMoreCovers
        self.authors = authors
        self.nativeAuthors = nativeAuthors
        self.artists = artists
        self.nativeArtists = nativeArtists
        self.status = status
        self.contentRating = contentRating
        self.description = description
        self.descriptionOptions = descriptionOptions
        self.tags = tags
    }
}

/// Abstraction for trackers capable of supplying rich series metadata for manual/diff-based pull.
protocol TrackerMetadataProvider: Sendable {
    var trackerId: String { get }
    var trackerName: String { get }

    func fetchMetadata(trackId: String) async throws -> TrackerMangaMetadata
    func fetchCoverPage(
        trackId: String,
        page: Int,
        type: String?,
        language: String?
    ) async throws -> TrackerCoverPage
}

extension TrackerMetadataProvider {
    func fetchCoverPage(
        trackId: String,
        page: Int,
        type: String?,
        language: String?
    ) async throws -> TrackerCoverPage {
        TrackerCoverPage(covers: [], totalCount: 0, page: page, hasNextPage: false)
    }
}

/// User-selectable fields within the manual metadata editor and tracker pull diff sheet.
enum MetadataEditableField: String, CaseIterable, Hashable, Sendable {
    case title
    case cover
    case authors
    case artists
    case status
    case contentRating
    case description
    case tags

    var editedKey: EditedKeys {
        switch self {
            case .title: .title
            case .cover: .cover
            case .authors: .authors
            case .artists: .artists
            case .status: .status
            case .contentRating: .contentRating
            case .description: .description
            case .tags: .tags
        }
    }
}

/// Selection returned by the tracker metadata diff sheet.
struct TrackerMetadataSelection: Equatable, Sendable {
    let selectedFields: Set<MetadataEditableField>
    let selectedTitle: String
    let selectedCoverUrl: String?
    let selectedAuthors: [String]?
    let selectedArtists: [String]?
    let selectedDescription: String?

    init(
        selectedFields: Set<MetadataEditableField>,
        selectedTitle: String,
        selectedCoverUrl: String? = nil,
        selectedAuthors: [String]? = nil,
        selectedArtists: [String]? = nil,
        selectedDescription: String? = nil
    ) {
        self.selectedFields = selectedFields
        self.selectedTitle = selectedTitle
        self.selectedCoverUrl = selectedCoverUrl
        self.selectedAuthors = selectedAuthors
        self.selectedArtists = selectedArtists
        self.selectedDescription = selectedDescription
    }
}
