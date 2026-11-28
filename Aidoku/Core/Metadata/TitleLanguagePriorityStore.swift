//
//  TitleLanguagePriorityStore.swift
//  Aidoku
//
//  Created by Dokuha on 11/27/26.
//

import Foundation

extension Notification.Name {
    static let forkTitleLanguagePriorityChanged = Self("Fork.titleLanguagePriorityChanged")
}

/// Local-only preference store controlling default title language fallback order for tracker metadata pulls.
final class TitleLanguagePriorityStore: @unchecked Sendable {
    static let shared = TitleLanguagePriorityStore()

    // Kept strictly under `Fork.` so BackupManager and PocketBase Sync never export or overwrite this local preference.
    static let userDefaultsKey = "Fork.metadataTitleLanguagePriority"
    static let defaultOrder = ["zh-Hant", "zh", "en", "ja", "ja-Latn"]

    struct LanguageInfo: Hashable, Sendable {
        let code: String
        let shortLabel: String
        let displayName: String
    }

    static let catalog: [LanguageInfo] = [
        .init(code: "zh-Hant", shortLabel: "繁中", displayName: "Traditional Chinese"),
        .init(code: "zh", shortLabel: "中文", displayName: "Chinese"),
        .init(code: "zh-Hans", shortLabel: "简中", displayName: "Simplified Chinese"),
        .init(code: "en", shortLabel: "EN", displayName: "English"),
        .init(code: "ja", shortLabel: "日本語", displayName: "Japanese"),
        .init(code: "ja-Latn", shortLabel: "Romaji", displayName: "Japanese (Romaji)"),
        .init(code: "ko", shortLabel: "한국어", displayName: "Korean"),
        .init(code: "ko-Latn", shortLabel: "KR", displayName: "Korean (Romaji)"),
        .init(code: "fr", shortLabel: "FR", displayName: "French"),
        .init(code: "de", shortLabel: "DE", displayName: "German"),
        .init(code: "es", shortLabel: "ES", displayName: "Spanish"),
        .init(code: "es-la", shortLabel: "ES-LA", displayName: "Spanish (LATAM)"),
        .init(code: "it", shortLabel: "IT", displayName: "Italian"),
        .init(code: "pt", shortLabel: "PT", displayName: "Portuguese"),
        .init(code: "pt-br", shortLabel: "PT-BR", displayName: "Portuguese (Brazil)"),
        .init(code: "vi", shortLabel: "VI", displayName: "Vietnamese"),
        .init(code: "id", shortLabel: "ID", displayName: "Indonesian"),
        .init(code: "th", shortLabel: "TH", displayName: "Thai"),
        .init(code: "ru", shortLabel: "RU", displayName: "Russian")
    ]

    private static let canonicalByLowercase: [String: LanguageInfo] = Dictionary(
        catalog.map { ($0.code.lowercased(), $0) },
        uniquingKeysWith: { first, _ in first }
    )

    private let userDefaults: UserDefaults
    private let lock = NSLock()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var priorityOrder: [String] {
        get {
            lock.lock()
            let stored = userDefaults.stringArray(forKey: Self.userDefaultsKey)
            lock.unlock()

            let normalized = Self.normalizeList(stored ?? [])
            return normalized.isEmpty ? Self.defaultOrder : normalized
        }
        set {
            let normalized = Self.normalizeList(newValue)
            let finalValue = normalized.isEmpty ? Self.defaultOrder : normalized

            lock.lock()
            userDefaults.set(finalValue, forKey: Self.userDefaultsKey)
            lock.unlock()

            NotificationCenter.default.post(name: .forkTitleLanguagePriorityChanged, object: nil)
        }
    }

    var summaryText: String {
        priorityOrder
            .prefix(3)
            .map { Self.shortLabel(for: $0) }
            .joined(separator: " → ")
    }

    func resetToDefault() {
        lock.lock()
        userDefaults.removeObject(forKey: Self.userDefaultsKey)
        lock.unlock()

        NotificationCenter.default.post(name: .forkTitleLanguagePriorityChanged, object: nil)
    }

    static func normalizeLanguageCode(_ raw: String) -> String {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        guard !trimmed.isEmpty else { return "unknown" }

        let lowered = trimmed.lowercased()
        if let info = canonicalByLowercase[lowered] {
            return info.code
        }

        let parts = lowered.split(separator: "-").map(String.init)
        guard let first = parts.first else { return "unknown" }
        if parts.count == 1 {
            return first
        }
        let rest = parts.dropFirst().map { part -> String in
            part.count == 4 ? part.capitalized : part
        }
        return ([first] + rest).joined(separator: "-")
    }

    /// Normalizes regional Chinese codes (e.g. `zh-hk`, `zh-tw`, `zh-Hant-TW`, `zh-cn`) into script tags used by the priority store.
    static func normalizeRegionLanguageCode(_ raw: String) -> String {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        let lowered = trimmed.lowercased()
        if lowered == "zh-hant" || lowered.hasPrefix("zh-hant-") || ["zh-hk", "zh-tw", "zh-mo"].contains(lowered) {
            return "zh-Hant"
        }
        if lowered == "zh-hans" || lowered.hasPrefix("zh-hans-") || ["zh-cn", "zh-sg"].contains(lowered) {
            return "zh-Hans"
        }
        return normalizeLanguageCode(raw)
    }

    static func shortLabel(for code: String) -> String {
        let normalized = normalizeLanguageCode(code)
        if normalized == "unknown" {
            return ForkL10n.string("METADATA_LANGUAGE_DEFAULT_SHORT")
        }
        if let info = canonicalByLowercase[normalized.lowercased()] {
            return info.shortLabel
        }
        return normalized.uppercased()
    }

    static func displayName(for code: String) -> String {
        let normalized = normalizeLanguageCode(code)
        if normalized == "unknown" {
            return ForkL10n.string("METADATA_LANGUAGE_DEFAULT_NAME")
        }
        if let info = canonicalByLowercase[normalized.lowercased()] {
            return info.displayName
        }
        if let localized = Locale.current.localizedString(forIdentifier: normalized), !localized.isEmpty {
            return localized
        }
        return normalized
    }

    /// Selects the highest-priority title matching `priorityOrder`, falling back to `defaultTitle` or the first primary option.
    static func resolvePreferredTitle(
        from options: [TrackerTitleOption],
        defaultTitle: String,
        priorityOrder: [String]
    ) -> TrackerTitleOption? {
        guard !options.isEmpty else { return nil }

        if let preferred = preferredOption(
            from: options,
            priorityOrder: priorityOrder,
            languageCode: \.languageCode,
            pickBest: bestCandidate(in:)
        ) {
            return preferred
        }

        let trimmedDefault = defaultTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if
            !trimmedDefault.isEmpty,
            let exactMatch = options.first(where: {
                $0.title.caseInsensitiveCompare(trimmedDefault) == .orderedSame
            })
        {
            return exactMatch
        }

        return options.first(where: \.isPrimary) ?? options.first
    }

    /// Selects the highest-priority description matching `priorityOrder`, falling back to English or the first option.
    static func resolvePreferredDescription(
        from options: [TrackerDescriptionOption],
        priorityOrder: [String]
    ) -> TrackerDescriptionOption? {
        guard !options.isEmpty else { return nil }

        if let preferred = preferredOption(
            from: options,
            priorityOrder: priorityOrder,
            languageCode: \.languageCode,
            pickBest: bestDescriptionCandidate(in:)
        ) {
            return preferred
        }

        let englishMatches = options.filter { $0.languageCode.caseInsensitiveCompare("en") == .orderedSame }
        return bestDescriptionCandidate(in: englishMatches) ?? options.first
    }

    /// Returns up to `limit` best title options across distinct languages ordered by `priorityOrder` first.
    static func quickLanguageOptions(
        from options: [TrackerTitleOption],
        priorityOrder: [String],
        limit: Int = 4
    ) -> [TrackerTitleOption] {
        quickDistinctLanguageOptions(
            from: options,
            priorityOrder: priorityOrder,
            limit: limit,
            languageCode: \.languageCode,
            pickBest: bestCandidate(in:)
        )
    }

    /// Returns up to `limit` best description options across distinct languages ordered by `priorityOrder` first.
    static func quickDescriptionOptions(
        from options: [TrackerDescriptionOption],
        priorityOrder: [String],
        limit: Int = 4
    ) -> [TrackerDescriptionOption] {
        quickDistinctLanguageOptions(
            from: options,
            priorityOrder: priorityOrder,
            limit: limit,
            languageCode: \.languageCode,
            pickBest: bestDescriptionCandidate(in:)
        )
    }

    /// Returns the ranking weight for description sources (`MangaBaka > MangaDex > Bangumi`).
    static func descriptionSourcePriorityScore(_ sourceName: String) -> Int {
        switch sourceName.lowercased() {
            case "mangabaka": 30
            case "mangadex": 20
            case "bangumi": 10
            default: 0
        }
    }

    /// Sorts description options by `priorityOrder`, then language code, then source priority (`MangaBaka > MangaDex > Bangumi`), then text.
    static func sortDescriptionOptions(
        _ options: [TrackerDescriptionOption],
        priorityOrder: [String]
    ) -> [TrackerDescriptionOption] {
        let priorityMap = Dictionary(
            normalizeList(priorityOrder).enumerated().map { ($0.element.lowercased(), $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        return options.sorted { lhs, rhs in
            let lRank = priorityMap[lhs.languageCode.lowercased()] ?? Int.max
            let rRank = priorityMap[rhs.languageCode.lowercased()] ?? Int.max
            if lRank != rRank { return lRank < rRank }
            if lhs.languageCode != rhs.languageCode {
                return lhs.languageCode.localizedCaseInsensitiveCompare(rhs.languageCode) == .orderedAscending
            }
            let lScore = descriptionSourcePriorityScore(lhs.sourceName)
            let rScore = descriptionSourcePriorityScore(rhs.sourceName)
            if lScore != rScore { return lScore > rScore }
            let sourceOrder = lhs.sourceName.localizedCaseInsensitiveCompare(rhs.sourceName)
            if sourceOrder != .orderedSame {
                return sourceOrder == .orderedAscending
            }
            return lhs.text < rhs.text
        }
    }

    private static func preferredOption<Option>(
        from options: [Option],
        priorityOrder: [String],
        languageCode: (Option) -> String,
        pickBest: ([Option]) -> Option?
    ) -> Option? {
        for code in normalizeList(priorityOrder) {
            let matching = options.filter {
                languageCode($0).caseInsensitiveCompare(code) == .orderedSame
            }
            if let best = pickBest(matching) {
                return best
            }
        }
        return nil
    }

    private static func quickDistinctLanguageOptions<Option>(
        from options: [Option],
        priorityOrder: [String],
        limit: Int,
        languageCode: (Option) -> String,
        pickBest: ([Option]) -> Option?
    ) -> [Option] {
        guard !options.isEmpty, limit > 0 else { return [] }

        var grouped: [String: [Option]] = [:]
        for option in options {
            grouped[languageCode(option).lowercased(), default: []].append(option)
        }

        var bestByLanguage: [String: Option] = [:]
        for (key, group) in grouped {
            if let best = pickBest(group) {
                bestByLanguage[key] = best
            }
        }

        var ordered: [Option] = []
        var seenLanguages: Set<String> = []

        for code in normalizeList(priorityOrder) {
            let key = code.lowercased()
            guard seenLanguages.insert(key).inserted, let candidate = bestByLanguage[key] else {
                continue
            }
            ordered.append(candidate)
        }

        let remainingKeys = bestByLanguage.keys
            .filter { !seenLanguages.contains($0) }
            .sorted { lhs, rhs in
                fallbackRank(for: lhs) < fallbackRank(for: rhs)
            }

        for key in remainingKeys {
            guard ordered.count < limit else { break }
            if let candidate = bestByLanguage[key] {
                ordered.append(candidate)
            }
        }

        return Array(ordered.prefix(limit))
    }

    private static func bestDescriptionCandidate(in candidates: [TrackerDescriptionOption]) -> TrackerDescriptionOption? {
        candidates.max { lhs, rhs in
            descriptionSourcePriorityScore(lhs.sourceName) < descriptionSourcePriorityScore(rhs.sourceName)
        }
    }

    private static func normalizeList(_ codes: [String]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for raw in codes {
            let normalized = normalizeLanguageCode(raw)
            guard normalized != "unknown" else { continue }
            let key = normalized.lowercased()
            if seen.insert(key).inserted {
                result.append(normalized)
            }
        }
        return result
    }

    private static func bestCandidate(in candidates: [TrackerTitleOption]) -> TrackerTitleOption? {
        candidates.max { lhs, rhs in
            candidateScore(lhs) < candidateScore(rhs)
        }
    }

    private static func candidateScore(_ option: TrackerTitleOption) -> Int {
        var score = 0
        if option.isPrimary { score += 100 }
        if option.traits.contains(where: { $0.caseInsensitiveCompare("official") == .orderedSame }) {
            score += 20
        }
        if option.traits.contains(where: { $0.caseInsensitiveCompare("native") == .orderedSame }) {
            score += 10
        }
        return score
    }

    private static func fallbackRank(for lowercasedCode: String) -> (Int, String) {
        let preferredFallbacks = ["zh-hant", "zh", "zh-hans", "en", "ja", "ja-latn", "ko"]
        if let index = preferredFallbacks.firstIndex(of: lowercasedCode) {
            return (index, lowercasedCode)
        }
        return (preferredFallbacks.count, lowercasedCode)
    }
}
