//
//  MetadataEnrichmentService.swift
//  Aidoku
//
//  Created by Dokuha on 11/27/26.
//

import Foundation

/// Fetches optional original-language staff names (AniList) and localized synopsis candidates (MangaDex & Bangumi).
struct MetadataEnrichmentService: Sendable {
    private static let userAgent = "Dokuha/1.0 (https://github.com/sfai05/Aidoku)"
    private static let requestTimeout: TimeInterval = 8

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchAniListNativeStaff(anilistId: Int) async -> (authors: [String], artists: [String]) {
        guard let url = URL(string: "https://graphql.anilist.co") else {
            return ([], [])
        }
        let query = """
        query ($id: Int) {
          Media(id: $id, type: MANGA) {
            staff(sort: [RELEVANCE, ID], perPage: 25) {
              edges {
                role
                node {
                  name {
                    full
                    native
                  }
                }
              }
            }
          }
        }
        """
        let payload: [String: Any] = [
            "query": query,
            "variables": ["id": anilistId]
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return ([], [])
        }

        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        guard
            let (data, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else {
            return ([], [])
        }
        return Self.parseAniListStaff(data: data)
    }

    func fetchLocalizedDescriptions(for series: MangaBakaSeries) async -> [TrackerDescriptionOption] {
        let searchQuery = (series.nativeTitle ?? series.title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchQuery.isEmpty else { return [] }

        var knownTitles = [series.title, series.nativeTitle ?? "", series.romanizedTitle ?? ""]
        knownTitles.append(contentsOf: (series.titles ?? []).map(\.title))
        let isNovel = series.type == .novel

        async let mangaDexResults = fetchMangaDexDescriptions(
            query: searchQuery,
            sourceLinks: series.source
        )
        async let bangumiResults = fetchBangumiDescriptions(
            keyword: searchQuery,
            knownTitles: knownTitles,
            isNovel: isNovel
        )

        let combined = await mangaDexResults + bangumiResults
        var result: [TrackerDescriptionOption] = []
        var seen: Set<String> = []
        for item in combined {
            let key = "\(item.languageCode.lowercased())|\(item.sourceName.lowercased())|\(item.text)"
            if seen.insert(key).inserted {
                result.append(item)
            }
        }
        return result
    }

    func fetchMangaDexDescriptions(
        query: String,
        sourceLinks: MangaBakaSeries.SourceLinks?
    ) async -> [TrackerDescriptionOption] {
        guard
            hasMatchableID(in: sourceLinks),
            var components = URLComponents(string: "https://api.mangadex.org/manga")
        else {
            return []
        }
        components.queryItems = [
            URLQueryItem(name: "title", value: query),
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "contentRating[]", value: "safe"),
            URLQueryItem(name: "contentRating[]", value: "suggestive"),
            URLQueryItem(name: "contentRating[]", value: "erotica"),
            URLQueryItem(name: "contentRating[]", value: "pornographic")
        ]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        guard
            let (data, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else {
            return []
        }
        return Self.parseMangaDexDescriptions(data: data, sourceLinks: sourceLinks)
    }

    func fetchBangumiDescriptions(
        keyword: String,
        knownTitles: [String],
        isNovel: Bool
    ) async -> [TrackerDescriptionOption] {
        guard let url = URL(string: "https://api.bgm.tv/v0/search/subjects?limit=8") else {
            return []
        }
        let payload: [String: Any] = [
            "keyword": keyword,
            "filter": ["type": [1]]
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return []
        }

        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        guard
            let (data, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else {
            return []
        }
        return Self.parseBangumiDescriptions(data: data, knownTitles: knownTitles, isNovel: isNovel)
    }
}

// MARK: - Pure Parsers (Unit-Tested)
extension MetadataEnrichmentService {
    static func parseAniListStaff(data: Data) -> (authors: [String], artists: [String]) {
        struct Response: Decodable {
            struct DataBox: Decodable {
                struct Media: Decodable {
                    struct StaffConnection: Decodable {
                        struct Edge: Decodable {
                            struct Node: Decodable {
                                struct Name: Decodable {
                                    let full: String?
                                    let native: String?
                                }
                                let name: Name?
                            }
                            let role: String?
                            let node: Node?
                        }
                        let edges: [Edge]?
                    }
                    let staff: StaffConnection?
                }
                let Media: Media?
            }
            let data: DataBox?
        }

        guard
            let decoded = try? JSONDecoder().decode(Response.self, from: data),
            let edges = decoded.data?.Media?.staff?.edges
        else {
            return ([], [])
        }

        let authorRoles: Set<String> = ["story", "story & art", "original story", "original creator"]
        let artistRoles: Set<String> = ["art", "story & art", "illustration"]

        var authors: [String] = []
        var artists: [String] = []

        for edge in edges {
            let baseRole = (edge.role ?? "")
                .split(separator: "(")
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""

            let isAuthor = authorRoles.contains(baseRole)
            let isArtist = artistRoles.contains(baseRole)
            guard isAuthor || isArtist else { continue }

            let nativeName = edge.node?.name?.native?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fullName = edge.node?.name?.full?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let resolvedName = (nativeName?.isEmpty == false ? nativeName : fullName), !resolvedName.isEmpty else {
                continue
            }

            if isAuthor {
                authors.append(resolvedName)
            }
            if isArtist {
                artists.append(resolvedName)
            }
        }

        return (authors.unique(), artists.unique())
    }

    static func parseMangaDexDescriptions(
        data: Data,
        sourceLinks: MangaBakaSeries.SourceLinks?
    ) -> [TrackerDescriptionOption] {
        struct Response: Decodable {
            struct MangaItem: Decodable {
                struct Attributes: Decodable {
                    let links: [String: String]?
                    let description: [String: String]?
                }
                let attributes: Attributes
            }
            let data: [MangaItem]?
        }

        guard
            let sourceLinks,
            let decoded = try? JSONDecoder().decode(Response.self, from: data),
            let items = decoded.data
        else {
            return []
        }

        var options: [TrackerDescriptionOption] = []
        var seen: Set<String> = []

        for item in items {
            let links = item.attributes.links ?? [:]
            guard matchesSourceLinks(links, sourceLinks: sourceLinks) else {
                continue
            }

            for (rawCode, rawText) in item.attributes.description ?? [:] {
                let code = TitleLanguagePriorityStore.normalizeRegionLanguageCode(rawCode)
                guard code != "unknown" else { continue }
                let cleaned = normalizeDescriptionText(rawText)
                guard !cleaned.isEmpty else { continue }

                let dedupKey = "\(code.lowercased())|\(cleaned)"
                if seen.insert(dedupKey).inserted {
                    options.append(
                        TrackerDescriptionOption(
                            languageCode: code,
                            text: cleaned,
                            sourceName: "MangaDex"
                        )
                    )
                }
            }
        }

        return options.sorted { lhs, rhs in
            let langOrder = lhs.languageCode.localizedCaseInsensitiveCompare(rhs.languageCode)
            if langOrder != .orderedSame {
                return langOrder == .orderedAscending
            }
            let sourceOrder = lhs.sourceName.localizedCaseInsensitiveCompare(rhs.sourceName)
            if sourceOrder != .orderedSame {
                return sourceOrder == .orderedAscending
            }
            return lhs.text < rhs.text
        }
    }

    static func parseBangumiDescriptions(
        data: Data,
        knownTitles: [String],
        isNovel: Bool
    ) -> [TrackerDescriptionOption] {
        struct Response: Decodable {
            struct Subject: Decodable {
                let name: String?
                let nameCn: String?
                let summary: String?
                let platform: String?
                let series: Bool?

                enum CodingKeys: String, CodingKey {
                    case name
                    case nameCn = "name_cn"
                    case summary
                    case platform
                    case series
                }
            }
            let data: [Subject]?
        }

        let normalizedKnown = Set(knownTitles.map(normalizeTitleForMatch).filter { !$0.isEmpty })
        guard
            !normalizedKnown.isEmpty,
            let decoded = try? JSONDecoder().decode(Response.self, from: data),
            let items = decoded.data
        else {
            return []
        }

        var options: [TrackerDescriptionOption] = []
        var seen: Set<String> = []

        for item in items {
            guard item.series != false else { continue }
            if let platform = item.platform?.trimmingCharacters(in: .whitespacesAndNewlines) {
                if !isNovel && platform == "小说" { continue }
                if isNovel && platform == "漫画" { continue }
            }

            let candidateTitles = [item.name, item.nameCn]
                .compactMap { $0.map(normalizeTitleForMatch) }
                .filter { !$0.isEmpty }
            guard candidateTitles.contains(where: { normalizedKnown.contains($0) }) else {
                continue
            }

            let cleaned = normalizeDescriptionText(item.summary ?? "")
            guard !cleaned.isEmpty else { continue }

            let language = inferBangumiLanguage(for: cleaned)
            let dedupKey = "\(language.lowercased())|\(cleaned)"
            if seen.insert(dedupKey).inserted {
                options.append(
                    TrackerDescriptionOption(
                        languageCode: language,
                        text: cleaned,
                        sourceName: "Bangumi"
                    )
                )
            }

            if language == "zh",
               containsHanCharacters(cleaned),
               let traditional = convertSimplifiedToTraditional(cleaned),
               !traditional.isEmpty {
                let hantKey = "zh-hant|\(traditional)"
                if seen.insert(hantKey).inserted {
                    options.append(
                        TrackerDescriptionOption(
                            languageCode: "zh-Hant",
                            text: traditional,
                            sourceName: "Bangumi"
                        )
                    )
                }
            }
        }

        return options
    }

    /// Performs approximate Simplified-to-Traditional Chinese script conversion using ICU (`Hans-Hant`).
    static func convertSimplifiedToTraditional(_ text: String) -> String? {
        text.applyingTransform(StringTransform("Hans-Hant"), reverse: false)
    }

    static func containsHanCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
                || (0x20000...0x2A6DF).contains(scalar.value)
        }
    }

    static func inferBangumiLanguage(for text: String) -> String {
        var totalScalars = 0
        var kanaScalars = 0

        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                continue
            }
            totalScalars += 1
            if (0x3040...0x309F).contains(scalar.value) || (0x30A0...0x30FF).contains(scalar.value) {
                kanaScalars += 1
            }
        }

        guard totalScalars > 0 else { return "zh" }
        return Double(kanaScalars) / Double(totalScalars) > 0.1 ? "ja" : "zh"
    }
}

private extension MetadataEnrichmentService {
    func hasMatchableID(in sourceLinks: MangaBakaSeries.SourceLinks?) -> Bool {
        guard let sourceLinks else { return false }
        return [
            sourceLinks.anilist?.id?.value,
            sourceLinks.myAnimeList?.id?.value,
            sourceLinks.kitsu?.id?.value,
            sourceLinks.mangaUpdates?.id?.value
        ].contains { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    static func matchesSourceLinks(
        _ links: [String: String],
        sourceLinks: MangaBakaSeries.SourceLinks
    ) -> Bool {
        let pairs: [(String?, String?)] = [
            (links["al"], sourceLinks.anilist?.id?.value),
            (links["mal"], sourceLinks.myAnimeList?.id?.value),
            (links["kt"], sourceLinks.kitsu?.id?.value),
            (links["mu"], sourceLinks.mangaUpdates?.id?.value)
        ]
        for (dexVal, mbVal) in pairs {
            guard
                let dexTrimmed = dexVal?.trimmingCharacters(in: .whitespacesAndNewlines),
                let mbTrimmed = mbVal?.trimmingCharacters(in: .whitespacesAndNewlines),
                !dexTrimmed.isEmpty,
                !mbTrimmed.isEmpty,
                dexTrimmed.caseInsensitiveCompare(mbTrimmed) == .orderedSame
            else {
                continue
            }
            return true
        }
        return false
    }

    static func normalizeDescriptionText(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizeTitleForMatch(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let halfwidth = trimmed.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? trimmed
        return halfwidth
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }
}
