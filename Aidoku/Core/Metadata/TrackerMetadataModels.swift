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
    let authors: [String]
    let artists: [String]
    let status: AidokuRunner.PublishingStatus?
    let description: String?
    let tags: [String]
}

/// Abstraction for trackers capable of supplying rich series metadata for manual/diff-based pull.
protocol TrackerMetadataProvider: Sendable {
    var trackerId: String { get }
    var trackerName: String { get }

    func fetchMetadata(trackId: String) async throws -> TrackerMangaMetadata
}

/// User-selectable fields within the manual metadata editor and tracker pull diff sheet.
enum MetadataEditableField: String, CaseIterable, Hashable, Sendable {
    case title
    case cover
    case authors
    case artists
    case status
    case description
    case tags

    var editedKey: EditedKeys {
        switch self {
            case .title: .title
            case .cover: .cover
            case .authors: .authors
            case .artists: .artists
            case .status: .status
            case .description: .description
            case .tags: .tags
        }
    }
}

/// Selection returned by the tracker metadata diff sheet.
struct TrackerMetadataSelection: Equatable, Sendable {
    let selectedFields: Set<MetadataEditableField>
    let selectedTitle: String
}
