//
//  MangaBakaMetadataProvider.swift
//  Aidoku
//
//  Created by Dokuha on 11/27/26.
//

import AidokuRunner
import Foundation

/// Fetches and normalizes series metadata from a linked MangaBaka entry.
struct MangaBakaMetadataProvider: TrackerMetadataProvider {
    let trackerId = "mangabaka"
    let trackerName = "MangaBaka"

    private let api: MangaBakaApi
    private let enrichmentService: MetadataEnrichmentService

    init(
        api: MangaBakaApi = TrackerManager.mangabaka.api,
        enrichmentService: MetadataEnrichmentService = .init()
    ) {
        self.api = api
        self.enrichmentService = enrichmentService
    }

    func fetchMetadata(trackId: String) async throws -> TrackerMangaMetadata {
        guard let seriesId = Int(trackId.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw MangaBakaTrackerError.invalidId
        }
        let series = try await api.getSeries(id: seriesId)

        async let nativeStaffTask: (authors: [String], artists: [String]) = {
            guard let anilistId = series.source?.anilist?.id?.intValue else {
                return ([], [])
            }
            return await enrichmentService.fetchAniListNativeStaff(anilistId: anilistId)
        }()
        async let externalDescriptionsTask = enrichmentService.fetchLocalizedDescriptions(for: series)
        async let initialCoverPageTask = fetchInitialCoverPage(trackId: trackId)

        let (nativeStaff, externalDescriptions, initialCoverPage) = await (
            nativeStaffTask,
            externalDescriptionsTask,
            initialCoverPageTask
        )

        return Self.map(
            series: series,
            trackId: trackId,
            nativeStaff: nativeStaff,
            externalDescriptions: externalDescriptions,
            initialCoverPage: initialCoverPage
        )
    }

    func fetchCoverPage(
        trackId: String,
        page: Int,
        type: String?,
        language: String?
    ) async throws -> TrackerCoverPage {
        guard let seriesId = Int(trackId.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw MangaBakaTrackerError.invalidId
        }
        let result = try await api.getSeriesImages(
            id: seriesId,
            page: page,
            limit: 50,
            type: type,
            language: language
        )
        return Self.mapCoverPage(
            images: result.images,
            pagination: result.pagination,
            requestedPage: max(page, 1),
            availableLanguages: result.availableLanguages,
            requestedType: type
        )
    }

    static func map(
        series: MangaBakaSeries,
        trackId: String,
        nativeStaff: (authors: [String], artists: [String]) = ([], []),
        externalDescriptions: [TrackerDescriptionOption] = [],
        initialCoverPage: TrackerCoverPage? = nil
    ) -> TrackerMangaMetadata {
        let defaultTitle = series.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleOptions = buildTitleOptions(series: series, defaultTitle: defaultTitle)

        let coverUrl = series.cover.raw.url?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyOrNil

        let authors = cleanUniqueStrings(series.authors ?? [])
        let artists = cleanUniqueStrings(series.artists ?? [])
        let nativeAuthors = cleanUniqueStrings(nativeStaff.authors)
        let nativeArtists = cleanUniqueStrings(nativeStaff.artists)
        let tags = cleanUniqueStrings((series.genres ?? []).map(formatGenre))
        let description = series.description?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyOrNil

        let descriptionOptions = buildDescriptionOptions(
            englishDescription: description,
            externalDescriptions: externalDescriptions
        )
        let coverGallery = buildCoverGallery(mainCoverUrl: coverUrl, initialCoverPage: initialCoverPage)

        return TrackerMangaMetadata(
            trackerId: "mangabaka",
            trackerName: "MangaBaka",
            trackId: trackId,
            defaultTitle: defaultTitle,
            titleOptions: titleOptions,
            coverUrl: coverUrl,
            coverOptions: coverGallery.options,
            availableCoverLanguages: initialCoverPage?.availableLanguages ?? [],
            initialCoverFilterType: initialCoverPage?.requestedType,
            hasLoadedInitialCovers: initialCoverPage != nil,
            totalCoverCount: coverGallery.totalCount,
            hasMoreCovers: coverGallery.hasMore,
            authors: authors,
            nativeAuthors: nativeAuthors,
            artists: artists,
            nativeArtists: nativeArtists,
            status: series.status.toRunnerStatus(),
            contentRating: mapContentRating(series.contentRating),
            description: description,
            descriptionOptions: descriptionOptions,
            tags: tags
        )
    }

    /// Maps MangaBaka API `content_rating` strings (`safe`, `suggestive`, `erotica`, `pornographic`) to runner ratings.
    static func mapContentRating(_ raw: String?) -> AidokuRunner.ContentRating? {
        guard let normalized = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !normalized.isEmpty
        else {
            return nil
        }

        return switch normalized {
            case "safe": .safe
            case "suggestive": .suggestive
            case "erotica", "pornographic": .nsfw
            default: nil
        }
    }

    static func mapCoverPage(
        images: [MangaBakaSeriesImage],
        pagination: MangaBakaPagination?,
        requestedPage: Int,
        availableLanguages: [String] = [],
        requestedType: String? = nil
    ) -> TrackerCoverPage {
        var seenRawUrls: Set<String> = []
        var covers: [TrackerCoverOption] = []

        for entry in images {
            guard
                let rawUrl = entry.image.raw.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                MangaMetadataService.isValidRemoteCoverURL(rawUrl),
                seenRawUrls.insert(rawUrl).inserted
            else {
                continue
            }

            let thumbUrl = [
                entry.image.x250?.x2,
                entry.image.x250?.x1,
                entry.image.x350?.x1,
                rawUrl
            ]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { MangaMetadataService.isValidRemoteCoverURL($0) } ?? rawUrl

            let langCode = TitleLanguagePriorityStore.normalizeRegionLanguageCode(entry.language ?? "unknown")
            let volumeLabel = entry.index?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil
            let typeName = entry.type?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil ?? "other"

            covers.append(
                TrackerCoverOption(
                    id: "mb-img-\(entry.id)",
                    rawUrl: rawUrl,
                    thumbnailUrl: thumbUrl,
                    volumeLabel: volumeLabel,
                    type: typeName,
                    languageCode: langCode,
                    isMain: false
                )
            )
        }

        let cleanLanguages = cleanUniqueStrings(availableLanguages)
        let totalCount = max(covers.count, pagination?.count ?? covers.count)
        let pageSize = max(pagination?.limit ?? 50, 1)
        let hasNextPage: Bool = if let next = pagination?.next, !next.isEmpty {
            true
        } else if let count = pagination?.count {
            count > requestedPage * pageSize
        } else {
            false
        }

        return TrackerCoverPage(
            covers: covers,
            totalCount: totalCount,
            page: requestedPage,
            hasNextPage: hasNextPage,
            availableLanguages: cleanLanguages,
            requestedType: requestedType
        )
    }

    static func formatGenre(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let specialCases: [String: String] = [
            "sci_fi": "Sci-Fi",
            "sci-fi": "Sci-Fi",
            "boys_love": "Boys' Love",
            "girls_love": "Girls' Love",
            "slice_of_life": "Slice of Life",
            "post_apocalyptic": "Post-Apocalyptic",
            "self_published": "Self-Published",
            "4_koma": "4-Koma",
            "full_color": "Full Color"
        ]
        let lowercased = trimmed.lowercased()
        if let special = specialCases[lowercased] {
            return special
        }

        let smallWords: Set<String> = ["of", "and", "the", "in", "to", "for"]
        let words = lowercased
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map(String.init)

        return words.enumerated().map { index, word in
            if index > 0 && smallWords.contains(word) {
                return word
            }
            return word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    private static func buildTitleOptions(series: MangaBakaSeries, defaultTitle: String) -> [TrackerTitleOption] {
        var candidates: [TrackerTitleOption] = []

        for entry in series.titles ?? [] {
            let cleanTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanTitle.isEmpty else { continue }
            let code = TitleLanguagePriorityStore.normalizeLanguageCode(entry.language ?? "unknown")
            candidates.append(
                TrackerTitleOption(
                    languageCode: code,
                    title: cleanTitle,
                    isPrimary: entry.isPrimary ?? false,
                    traits: entry.traits ?? []
                )
            )
        }

        let hasExplicitTitles = !candidates.isEmpty

        if !defaultTitle.isEmpty, !candidates.contains(where: { $0.title.caseInsensitiveCompare(defaultTitle) == .orderedSame }) {
            candidates.append(
                TrackerTitleOption(
                    languageCode: "unknown",
                    title: defaultTitle,
                    isPrimary: !hasExplicitTitles,
                    traits: []
                )
            )
        }

        if
            let native = series.nativeTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
            !native.isEmpty,
            !candidates.contains(where: { $0.title.caseInsensitiveCompare(native) == .orderedSame })
        {
            let nativeCode = series.originalLanguage
                .map { TitleLanguagePriorityStore.normalizeLanguageCode($0) }
                ?? "native"
            candidates.append(
                TrackerTitleOption(
                    languageCode: nativeCode,
                    title: native,
                    isPrimary: !hasExplicitTitles,
                    traits: ["native"]
                )
            )
        }

        if
            let romanized = series.romanizedTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
            !romanized.isEmpty,
            !candidates.contains(where: { $0.title.caseInsensitiveCompare(romanized) == .orderedSame })
        {
            let baseLang = series.originalLanguage
                .map { TitleLanguagePriorityStore.normalizeLanguageCode($0) }
                ?? "ja"
            let romanizedCode = TitleLanguagePriorityStore.normalizeLanguageCode("\(baseLang)-Latn")
            candidates.append(
                TrackerTitleOption(
                    languageCode: romanizedCode,
                    title: romanized,
                    isPrimary: !hasExplicitTitles,
                    traits: ["native"]
                )
            )
        }

        return deduplicateOptions(candidates)
    }

    private static func deduplicateOptions(_ options: [TrackerTitleOption]) -> [TrackerTitleOption] {
        var bestByKey: [String: TrackerTitleOption] = [:]
        var orderedKeys: [String] = []

        for option in options {
            let key = "\(option.languageCode.lowercased())|\(option.title.lowercased())"
            if let existing = bestByKey[key] {
                if optionQuality(option) > optionQuality(existing) {
                    bestByKey[key] = option
                }
            } else {
                bestByKey[key] = option
                orderedKeys.append(key)
            }
        }

        return orderedKeys.compactMap { bestByKey[$0] }
    }

    private static func optionQuality(_ option: TrackerTitleOption) -> Int {
        var score = 0
        if option.languageCode != "unknown" { score += 50 }
        if option.isPrimary { score += 20 }
        score += option.traits.count * 5
        return score
    }

    private static func cleanUniqueStrings(_ values: [String]) -> [String] {
        values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .unique()
    }

    private func fetchInitialCoverPage(trackId: String) async -> TrackerCoverPage? {
        do {
            let volumes = try await fetchCoverPage(trackId: trackId, page: 1, type: "volume", language: nil)
            if !volumes.covers.isEmpty || volumes.totalCount > 0 {
                return volumes
            }
            return try await fetchCoverPage(trackId: trackId, page: 1, type: nil, language: nil)
        } catch {
            return nil
        }
    }

    private static func buildDescriptionOptions(
        englishDescription: String?,
        externalDescriptions: [TrackerDescriptionOption]
    ) -> [TrackerDescriptionOption] {
        var options: [TrackerDescriptionOption] = []
        var seen: Set<String> = []

        if let englishDescription, !englishDescription.isEmpty {
            let option = TrackerDescriptionOption(
                languageCode: "en",
                text: englishDescription,
                sourceName: "MangaBaka"
            )
            seen.insert("en|\(englishDescription)")
            options.append(option)
        }

        for option in externalDescriptions {
            let trimmed = option.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = "\(option.languageCode.lowercased())|\(trimmed)"
            guard seen.insert(key).inserted else { continue }
            options.append(
                TrackerDescriptionOption(
                    languageCode: option.languageCode,
                    text: trimmed,
                    sourceName: option.sourceName
                )
            )
        }

        return options
    }

    private struct CoverGallerySummary {
        let options: [TrackerCoverOption]
        let totalCount: Int
        let hasMore: Bool
    }

    private static func buildCoverGallery(
        mainCoverUrl: String?,
        initialCoverPage: TrackerCoverPage?
    ) -> CoverGallerySummary {
        var options: [TrackerCoverOption] = []
        var seenRawUrls: Set<String> = []

        let validMainCover = mainCoverUrl.flatMap {
            MangaMetadataService.isValidRemoteCoverURL($0) ? $0 : nil
        }

        if let validMainCover {
            options.append(
                TrackerCoverOption(
                    id: "main",
                    rawUrl: validMainCover,
                    thumbnailUrl: validMainCover,
                    volumeLabel: nil,
                    type: "main",
                    languageCode: "unknown",
                    isMain: true
                )
            )
            seenRawUrls.insert(validMainCover)
        }

        let pageCovers = initialCoverPage?.covers ?? []
        for cover in pageCovers where seenRawUrls.insert(cover.rawUrl).inserted {
            options.append(cover)
        }

        let hasMore = initialCoverPage?.hasNextPage ?? false
        let mainAlreadyInPage = validMainCover != nil && pageCovers.contains { $0.rawUrl == validMainCover }
        let estimatedTotal = (initialCoverPage?.totalCount ?? 0)
            + ((validMainCover != nil && !mainAlreadyInPage) ? 1 : 0)
        let totalCount = hasMore ? max(options.count, estimatedTotal) : options.count

        return CoverGallerySummary(options: options, totalCount: totalCount, hasMore: hasMore)
    }
}

private extension String {
    var nonEmptyOrNil: String? {
        isEmpty ? nil : self
    }
}
