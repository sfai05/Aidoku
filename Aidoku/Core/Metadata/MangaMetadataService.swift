//
//  MangaMetadataService.swift
//  Aidoku
//
//  Created by Dokuha on 11/27/26.
//

import AidokuRunner
import CoreData
import Foundation
import UIKit

struct MangaMetadataSnapshot: Equatable, Sendable {
    var cover: String?
    var title: String
    var authors: [String]
    var artists: [String]
    var status: AidokuRunner.PublishingStatus
    var contentRating: AidokuRunner.ContentRating
    var description: String?
    var tags: [String]
    var editedKeys: EditedKeys

    init(
        cover: String?,
        title: String,
        authors: [String],
        artists: [String],
        status: AidokuRunner.PublishingStatus,
        contentRating: AidokuRunner.ContentRating = .safe,
        description: String?,
        tags: [String],
        editedKeys: EditedKeys
    ) {
        self.cover = cover
        self.title = title
        self.authors = authors
        self.artists = artists
        self.status = status
        self.contentRating = MangaMetadataService.normalizedContentRating(contentRating)
        self.description = description
        self.tags = tags
        self.editedKeys = editedKeys
    }

    init(manga: AidokuRunner.Manga, editedKeys: EditedKeys) {
        self.cover = manga.cover
        self.title = manga.title
        self.authors = manga.authors ?? []
        self.artists = manga.artists ?? []
        self.status = manga.status
        self.contentRating = MangaMetadataService.normalizedContentRating(manga.contentRating)
        self.description = manga.description
        self.tags = manga.tags ?? []
        self.editedKeys = editedKeys
    }
}

struct MetadataLoadResult: Sendable {
    let snapshot: MangaMetadataSnapshot
    let mangaBakaTrackItem: TrackItem?
}

struct MetadataSaveRequest {
    let manga: AidokuRunner.Manga
    let source: AidokuRunner.Source?
    let snapshot: MangaMetadataSnapshot
    let editedFields: Set<MetadataEditableField>
    let resetFields: Set<MetadataEditableField>
    let pendingCoverImage: UIImage?
}

struct MetadataSaveResult: Sendable {
    let updatedManga: AidokuRunner.Manga
    let editedKeys: EditedKeys
}

enum MetadataSaveError: LocalizedError, Equatable {
    case emptyTitle
    case invalidCoverURL
    case coverWriteFailed
    case mangaNotFound
    case sourceUnavailableForReset
    case sourceResetFailed(String)
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
            case .emptyTitle:
                ForkL10n.string("METADATA_ERROR_EMPTY_TITLE")
            case .invalidCoverURL:
                ForkL10n.string("METADATA_ERROR_INVALID_COVER_URL")
            case .coverWriteFailed:
                ForkL10n.string("METADATA_ERROR_COVER_SAVE")
            case .mangaNotFound:
                ForkL10n.string("METADATA_ERROR_MANGA_NOT_FOUND")
            case .sourceUnavailableForReset:
                ForkL10n.string("METADATA_ERROR_SOURCE_UNAVAILABLE_FOR_RESET")
            case let .sourceResetFailed(message):
                ForkL10n.format("METADATA_ERROR_SOURCE_RESET_FAILED_FORMAT", message)
            case let .saveFailed(message):
                message
        }
    }
}

enum MangaMetadataService {
    /// Normalizes `.unknown` to `.safe` because Core Data stores only `safe`, `suggestive`, and `nsfw`.
    static func normalizedContentRating(_ rating: AidokuRunner.ContentRating) -> AidokuRunner.ContentRating {
        switch rating {
            case .unknown, .safe: .safe
            case .suggestive: .suggestive
            case .nsfw: .nsfw
        }
    }

    /// Maps runner `ContentRating` to Core Data `MangaObject.nsfw` (`0 = safe, 1 = suggestive, 2 = nsfw`).
    static func coreDataNSFWValue(for rating: AidokuRunner.ContentRating) -> Int16 {
        switch rating {
            case .unknown, .safe: 0
            case .suggestive: 1
            case .nsfw: 2
        }
    }

    static func parsePersonList(_ text: String) -> [String] {
        text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .unique()
    }

    static func formatPersonList(_ people: [String]) -> String {
        people
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .unique()
            .joined(separator: ", ")
    }

    static func isValidRemoteCoverURL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            let components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host,
            !host.isEmpty
        else {
            return false
        }
        return true
    }

    static func managedCustomCoverFileURL(
        for coverURLString: String,
        documentsDirectory: URL = FileManager.default.documentDirectory
    ) -> URL? {
        guard
            let url = URL(string: coverURLString),
            url.scheme == "aidoku-image"
        else {
            return nil
        }

        let rawPath = url.host.map { $0 + url.path } ?? url.path
        let trimmed = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard trimmed.hasPrefix("Covers/") else { return nil }

        let coversDir = documentsDirectory
            .appendingPathComponent("Covers", isDirectory: true)
            .standardizedFileURL
        let coversPrefix = coversDir.path.hasSuffix("/") ? coversDir.path : "\(coversDir.path)/"
        let candidate = documentsDirectory
            .appendingPathComponent(trimmed)
            .standardizedFileURL

        guard
            candidate.path.hasPrefix(coversPrefix),
            candidate.lastPathComponent != "Covers"
        else {
            return nil
        }
        return candidate
    }

    static func loadInitialState(for manga: AidokuRunner.Manga) async -> MetadataLoadResult {
        await CoreDataManager.shared.container.performBackgroundTask { context in
            let object = CoreDataManager.shared.getManga(mangaId: manga.identifier, context: context)
            let resolvedManga = object?.toNewManga() ?? manga
            let editedKeys = EditedKeys(rawValue: object?.editedKeys ?? 0)
            let trackItem = CoreDataManager.shared.getTrack(
                trackerId: "mangabaka",
                mangaId: manga.identifier,
                context: context
            )?.toItem()
            return MetadataLoadResult(
                snapshot: MangaMetadataSnapshot(manga: resolvedManga, editedKeys: editedKeys),
                mangaBakaTrackItem: trackItem
            )
        }
    }

    static func fetchMangaBakaTrackItem(for mangaId: MangaIdentifier) async -> TrackItem? {
        await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.getTrack(
                trackerId: "mangabaka",
                mangaId: mangaId,
                context: context
            )?.toItem()
        }
    }

    static func save(_ request: MetadataSaveRequest) async throws -> MetadataSaveResult {
        let trimmedTitle = request.snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !request.resetFields.contains(.title), trimmedTitle.isEmpty {
            throw MetadataSaveError.emptyTitle
        }

        var nextSnapshot = request.snapshot
        nextSnapshot.title = trimmedTitle
        nextSnapshot.authors = nextSnapshot.authors
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .unique()
        nextSnapshot.artists = nextSnapshot.artists
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .unique()
        nextSnapshot.tags = nextSnapshot.tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .unique()
        nextSnapshot.description = nextSnapshot.description?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        var fetchedSourceManga: AidokuRunner.Manga?
        if !request.resetFields.isEmpty {
            guard !request.manga.isLocal(), let source = request.source else {
                throw MetadataSaveError.sourceUnavailableForReset
            }
            do {
                fetchedSourceManga = try await source.getMangaUpdate(
                    manga: request.manga,
                    needsDetails: true,
                    needsChapters: false
                )
            } catch {
                throw MetadataSaveError.sourceResetFailed(error.localizedDescription)
            }
        }

        if
            request.pendingCoverImage == nil,
            !request.resetFields.contains(.cover),
            request.editedFields.contains(.cover),
            let cover = nextSnapshot.cover?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        {
            if !cover.hasPrefix("aidoku-image://") && !isValidRemoteCoverURL(cover) {
                throw MetadataSaveError.invalidCoverURL
            }
            nextSnapshot.cover = cover
        }

        var newlyWrittenCoverURL: URL?
        if let pendingImage = request.pendingCoverImage, !request.resetFields.contains(.cover) {
            let written = try writeCoverImage(pendingImage)
            nextSnapshot.cover = written.aidokuURLString
            newlyWrittenCoverURL = written.fileURL
        }

        let editedBits = bitmask(for: request.editedFields)
        let resetBits = bitmask(for: request.resetFields).subtracting(editedBits)

        do {
            let persistInput = CoreDataPersistInput(
                manga: request.manga,
                snapshot: nextSnapshot,
                editedFields: request.editedFields,
                resetFields: request.resetFields,
                editedBits: editedBits,
                resetBits: resetBits,
                fetchedSourceManga: fetchedSourceManga
            )
            let outcome = try await persistToCoreData(persistInput)

            if
                let previousCover = outcome.previousCover,
                previousCover != outcome.finalCover,
                let oldFileURL = managedCustomCoverFileURL(for: previousCover)
            {
                oldFileURL.removeItem()
            }

            SyncTombstoneStore.shared.recordMangaFieldUpdates(
                mangaId: request.manga.identifier,
                editedBits: editedBits,
                resetBits: resetBits
            )

            var displayManga = outcome.updatedManga
            displayManga.chapters = request.manga.chapters

            await MainActor.run {
                NotificationCenter.default.post(name: .updateMangaDetails, object: displayManga)
                NotificationCenter.default.post(name: .updateLibrary, object: nil)
            }

            return MetadataSaveResult(
                updatedManga: displayManga,
                editedKeys: outcome.finalEditedKeys
            )
        } catch {
            // Avoid leaking orphaned cover files if Core Data save failed.
            newlyWrittenCoverURL?.removeItem()
            throw error
        }
    }
}

private extension MangaMetadataService {
    struct CoreDataPersistInput {
        let manga: AidokuRunner.Manga
        let snapshot: MangaMetadataSnapshot
        let editedFields: Set<MetadataEditableField>
        let resetFields: Set<MetadataEditableField>
        let editedBits: EditedKeys
        let resetBits: EditedKeys
        let fetchedSourceManga: AidokuRunner.Manga?
    }

    struct CoreDataPersistOutcome: Sendable {
        let updatedManga: AidokuRunner.Manga
        let previousCover: String?
        let finalCover: String?
        let finalEditedKeys: EditedKeys
    }

    static func bitmask(for fields: Set<MetadataEditableField>) -> EditedKeys {
        fields.reduce(into: EditedKeys()) { result, field in
            result.insert(field.editedKey)
        }
    }

    static func writeCoverImage(_ image: UIImage) throws -> (aidokuURLString: String, fileURL: URL) {
        let targetDirectory = FileManager.default.documentDirectory.appendingPathComponent("Covers", isDirectory: true)
        let ext = if #available(iOS 17.0, *) { "heic" } else { "png" }
        var targetURL = targetDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        while targetURL.exists {
            targetURL = targetDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        }
        targetDirectory.createDirectory()

        let data: Data? = if #available(iOS 17.0, *) {
            image.heicData() ?? image.pngData()
        } else {
            image.pngData()
        }
        guard let data else {
            throw MetadataSaveError.coverWriteFailed
        }
        do {
            try data.write(to: targetURL, options: .atomic)
        } catch {
            throw MetadataSaveError.coverWriteFailed
        }
        return ("aidoku-image:///Covers/\(targetURL.lastPathComponent)", targetURL)
    }

    static func persistToCoreData(_ input: CoreDataPersistInput) async throws -> CoreDataPersistOutcome {
        try await CoreDataManager.shared.container.performBackgroundTask { context in
            guard let object = CoreDataManager.shared.getManga(mangaId: input.manga.identifier, context: context) else {
                throw MetadataSaveError.mangaNotFound
            }

            let previousCover = object.cover
            var updatedKeys = EditedKeys(rawValue: object.editedKeys)
            updatedKeys.formUnion(input.editedBits)
            updatedKeys.subtract(input.resetBits)

            applyFields(to: object, input: input)
            object.editedKeys = updatedKeys.rawValue

            do {
                try context.save()
            } catch {
                throw MetadataSaveError.saveFailed(error.localizedDescription)
            }

            return CoreDataPersistOutcome(
                updatedManga: object.toNewManga(),
                previousCover: previousCover,
                finalCover: object.cover,
                finalEditedKeys: updatedKeys
            )
        }
    }

    static func applyFields(to object: MangaObject, input: CoreDataPersistInput) {
        let fetchedSourceManga = input.fetchedSourceManga
        let snapshot = input.snapshot
        let editedFields = input.editedFields
        let resetFields = input.resetFields

        if resetFields.contains(.title) {
            if let sourceTitle = fetchedSourceManga?.title {
                object.title = sourceTitle
            }
        } else if editedFields.contains(.title) {
            object.title = snapshot.title
        }

        if resetFields.contains(.authors) {
            if let fetchedSourceManga {
                object.author = fetchedSourceManga.authors.flatMap { $0.isEmpty ? nil : $0.joined(separator: ", ") }
            }
        } else if editedFields.contains(.authors) {
            object.author = snapshot.authors.isEmpty ? nil : snapshot.authors.joined(separator: ", ")
        }

        if resetFields.contains(.artists) {
            if let fetchedSourceManga {
                object.artist = fetchedSourceManga.artists.flatMap { $0.isEmpty ? nil : $0.joined(separator: ", ") }
            }
        } else if editedFields.contains(.artists) {
            object.artist = snapshot.artists.isEmpty ? nil : snapshot.artists.joined(separator: ", ")
        }

        if resetFields.contains(.description) {
            if let fetchedSourceManga {
                object.desc = fetchedSourceManga.description
            }
        } else if editedFields.contains(.description) {
            object.desc = snapshot.description
        }

        if resetFields.contains(.tags) {
            if let fetchedSourceManga {
                object.tags = fetchedSourceManga.tags ?? []
            }
        } else if editedFields.contains(.tags) {
            object.tags = snapshot.tags
        }

        if resetFields.contains(.cover) {
            if let fetchedSourceManga {
                object.cover = fetchedSourceManga.cover
            }
        } else if editedFields.contains(.cover) {
            object.cover = snapshot.cover
        }

        if resetFields.contains(.status) {
            if let fetchedSourceManga {
                object.status = Int16(fetchedSourceManga.status.rawValue)
            }
        } else if editedFields.contains(.status) {
            object.status = Int16(snapshot.status.rawValue)
        }

        if resetFields.contains(.contentRating) {
            if let fetchedSourceManga {
                object.nsfw = Self.coreDataNSFWValue(for: fetchedSourceManga.contentRating)
            }
        } else if editedFields.contains(.contentRating) {
            object.nsfw = Self.coreDataNSFWValue(for: snapshot.contentRating)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
