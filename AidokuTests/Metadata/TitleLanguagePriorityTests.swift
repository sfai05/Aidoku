//
//  TitleLanguagePriorityTests.swift
//  AidokuTests
//

@testable import Aidoku
import Foundation
import Testing

@Suite struct TitleLanguagePriorityTests {
    @Test func resolvesTitleByConfiguredPriorityOrder() {
        let options: [TrackerTitleOption] = [
            .init(languageCode: "en", title: "Frieren: Beyond Journey's End", isPrimary: true, traits: ["official"]),
            .init(languageCode: "zh", title: "葬送的芙莉莲", isPrimary: true, traits: []),
            .init(languageCode: "zh-Hant", title: "葬送的芙莉蓮", isPrimary: true, traits: []),
            .init(languageCode: "ja", title: "葬送のフリーレン", isPrimary: true, traits: ["native"])
        ]

        let zhFirst = TitleLanguagePriorityStore.resolvePreferredTitle(
            from: options,
            defaultTitle: "Frieren: Beyond Journey's End",
            priorityOrder: ["zh", "zh-Hant", "en"]
        )
        #expect(zhFirst?.title == "葬送的芙莉莲")
        #expect(zhFirst?.languageCode == "zh")

        let zhHantFirst = TitleLanguagePriorityStore.resolvePreferredTitle(
            from: options,
            defaultTitle: "Frieren: Beyond Journey's End",
            priorityOrder: ["zh-Hant", "zh", "en"]
        )
        #expect(zhHantFirst?.title == "葬送的芙莉蓮")
        #expect(zhHantFirst?.languageCode == "zh-Hant")

        let fallbackWhenMissing = TitleLanguagePriorityStore.resolvePreferredTitle(
            from: [options[0], options[3]],
            defaultTitle: "Frieren: Beyond Journey's End",
            priorityOrder: ["zh", "zh-Hant", "en"]
        )
        #expect(fallbackWhenMissing?.title == "Frieren: Beyond Journey's End")
    }

    @Test func ranksPrimaryAndOfficialWithinSameLanguage() {
        let options: [TrackerTitleOption] = [
            .init(languageCode: "en", title: "Frieren at the Funeral", isPrimary: false, traits: []),
            .init(languageCode: "en", title: "Frieren: Beyond Journey's End", isPrimary: true, traits: ["official"]),
            .init(languageCode: "en", title: "Frieren the Slayer", isPrimary: false, traits: [])
        ]

        let picked = TitleLanguagePriorityStore.resolvePreferredTitle(
            from: options,
            defaultTitle: "Frieren at the Funeral",
            priorityOrder: ["en"]
        )
        #expect(picked?.title == "Frieren: Beyond Journey's End")
    }

    @Test func quickLanguageOptionsFollowPriorityOrderAndLimit() {
        let options: [TrackerTitleOption] = [
            .init(languageCode: "fr", title: "Frieren", isPrimary: true, traits: ["official"]),
            .init(languageCode: "en", title: "Frieren: Beyond Journey's End", isPrimary: true, traits: ["official"]),
            .init(languageCode: "ja", title: "葬送のフリーレン", isPrimary: true, traits: ["native"]),
            .init(languageCode: "zh", title: "葬送的芙莉莲", isPrimary: true, traits: []),
            .init(languageCode: "zh-Hant", title: "葬送的芙莉蓮", isPrimary: true, traits: []),
            .init(languageCode: "ko", title: "장송의 프리렌", isPrimary: true, traits: ["official"])
        ]

        let quick = TitleLanguagePriorityStore.quickLanguageOptions(
            from: options,
            priorityOrder: ["zh", "zh-Hant", "ja", "en"],
            limit: 4
        )
        #expect(quick.map(\.languageCode) == ["zh", "zh-Hant", "ja", "en"])
    }

    @Test func persistsLocallyAndIsExcludedFromBackupAndSync() {
        let suiteName = "ForkTitlePriorityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        let store = TitleLanguagePriorityStore(userDefaults: defaults)
        #expect(store.priorityOrder == TitleLanguagePriorityStore.defaultOrder)

        store.priorityOrder = ["zh", "zh-hant", "EN", "zh"]
        #expect(store.priorityOrder == ["zh", "zh-Hant", "en"])

        store.resetToDefault()
        #expect(store.priorityOrder == TitleLanguagePriorityStore.defaultOrder)

        // Must stay local-only and excluded from BackupManager and PocketBase Sync.
        let key = TitleLanguagePriorityStore.userDefaultsKey
        #expect(key.hasPrefix("Fork."))
        #expect(!BackupManager.allowedSettingsPrefixes.contains { key.hasPrefix($0) })
        #expect(!SyncMerger.isAllowedSyncSettingKey(key))
    }
}
