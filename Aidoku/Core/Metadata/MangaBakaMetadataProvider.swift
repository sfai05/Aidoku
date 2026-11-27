//
//  MangaBakaMetadataProvider.swift
//  Aidoku
//
//  Created by Kodoku on 11/27/26.
//

import Foundation

/// Fetches and normalizes series metadata from a linked MangaBaka entry.
struct MangaBakaMetadataProvider: TrackerMetadataProvider {
    let trackerId = "mangabaka"
    let trackerName = "MangaBaka"

    private let api: MangaBakaApi

    init(api: MangaBakaApi = TrackerManager.mangabaka.api) {
        self.api = api
    }

    func fetchMetadata(trackId: String) async throws -> TrackerMangaMetadata {
        guard let seriesId = Int(trackId.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw MangaBakaTrackerError.invalidId
        }
        let series = try await api.getSeries(id: seriesId)
        return Self.map(series: series, trackId: trackId)
    }

    static func map(series: MangaBakaSeries, trackId: String) -> TrackerMangaMetadata {
        let defaultTitle = series.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleOptions = buildTitleOptions(series: series, defaultTitle: defaultTitle)

        let coverUrl = series.cover.raw.url?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyOrNil

        let authors = cleanUniqueStrings(series.authors ?? [])
        let artists = cleanUniqueStrings(series.artists ?? [])
        let tags = cleanUniqueStrings((series.genres ?? []).map(formatGenre))
        let description = series.description?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyOrNil

        return TrackerMangaMetadata(
            trackerId: "mangabaka",
            trackerName: "MangaBaka",
            trackId: trackId,
            defaultTitle: defaultTitle,
            titleOptions: titleOptions,
            coverUrl: coverUrl,
            authors: authors,
            artists: artists,
            status: series.status.toRunnerStatus(),
            description: description,
            tags: tags
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
}

private extension String {
    var nonEmptyOrNil: String? {
        isEmpty ? nil : self
    }
}
