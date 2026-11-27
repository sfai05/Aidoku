//
//  SyncMerger.swift
//  Aidoku
//

import Foundation

struct SyncMergeResult: Equatable, Sendable {
    let mergedEnvelope: SyncEnvelope
    let localNeedsApply: Bool
    let remoteNeedsUpload: Bool
    let stats: SyncSnapshotStats
}

enum SyncMerger {
    static let defaultTombstoneTTL: TimeInterval = 90 * 86_400

    private static let excludedSettingsKeys: Set<String> = [
        AppSettings.browse.sourceLists.key,
        AppSettings.general.icloudSync.key
    ]

    private static let excludedSettingsPrefixes: [String] = [
        "Fork.",
        SyncConfiguration.Key.prefix,
        "Flag.",
        "Data."
    ]

    private static let sensitiveSettingsKeywords: [String] = [
        "login",
        "password",
        "token",
        "auth",
        "cookie"
    ]

    static func merge(
        local: SyncEnvelope,
        remote: SyncEnvelope,
        deviceId: String,
        deviceName: String,
        now: Date = Date(),
        includeSettings: Bool = false,
        localSettingsModified: Bool? = nil,
        tombstoneTTL: TimeInterval = defaultTombstoneTTL
    ) -> SyncMergeResult {
        var tombstones = mergeTombstones(local: local.tombstones, remote: remote.tombstones)
        let inputs = MergeInputs(local: local, remote: remote)

        let (mergedCategories, activeCategoryTitles) = mergeCategories(
            inputs: inputs,
            tombstones: &tombstones
        )

        let (mergedLibrary, deletedLibraryIds) = mergeLibrary(
            inputs: inputs,
            activeCategoryTitles: activeCategoryTitles,
            tombstones: &tombstones
        )

        let mergedManga = mergeManga(
            inputs: inputs,
            deletedLibraryIds: deletedLibraryIds,
            mergedFieldUpdates: tombstones.mangaFieldUpdates
        )

        let mergedChapters = mergeChapters(
            inputs: inputs,
            deletedLibraryIds: deletedLibraryIds
        )

        let (mergedHistory, suppressedChapterDeletes) = mergeHistory(
            local: local.backup.history ?? [],
            remote: remote.backup.history ?? [],
            tombstones: &tombstones
        )

        let mergedSessions = mergeReadingSessions(
            local: local.backup.readingSessions ?? [],
            remote: remote.backup.readingSessions ?? [],
            filters: SessionFilterContext(
                suppressedChapterDeletes: suppressedChapterDeletes,
                mangaHistoryDeletes: Dictionary(
                    tombstones.mangaHistory.map { ($0.mangaIdentifier, $0.deletedAt) },
                    uniquingKeysWith: max
                ),
                historyClearedAt: tombstones.historyClearedAt
            )
        )

        let mergedUpdates = mergeUpdates(
            local: local.backup.updates ?? [],
            remote: remote.backup.updates ?? [],
            deletedLibraryIds: deletedLibraryIds
        )

        let mergedTracks = mergeTracks(
            inputs: inputs,
            deletedLibraryIds: deletedLibraryIds,
            tombstones: &tombstones
        )

        let mergedVocab = mergeVocab(
            local: local.backup.vocabulary ?? [],
            remote: remote.backup.vocabulary ?? []
        )

        let mergedSources = mergeSources(
            local: local.backup.sources ?? [],
            remote: remote.backup.sources ?? [],
            inputs: inputs
        )

        let mergedSourceLists = mergeSourceLists(
            local: local.backup.sourceLists ?? [],
            remote: remote.backup.sourceLists ?? []
        )

        let mergedSettings = mergeSettings(
            local: local.backup.settings,
            remote: remote.backup.settings,
            inputs: inputs,
            includeSettings: includeSettings,
            localSettingsModified: localSettingsModified
        )

        let cutoffDate = now.addingTimeInterval(-tombstoneTTL)
        let activeTombstones = pruneTombstones(tombstones, olderThan: cutoffDate).canonicalized()

        let mergedBackup = Backup(
            library: mergedLibrary,
            history: mergedHistory,
            manga: mergedManga,
            chapters: mergedChapters,
            trackItems: mergedTracks,
            readingSessions: mergedSessions,
            vocabulary: mergedVocab,
            updates: mergedUpdates,
            categories: mergedCategories,
            sources: mergedSources,
            sourceLists: mergedSourceLists,
            settings: mergedSettings,
            date: now,
            name: nil,
            automatic: true,
            version: local.backup.version ?? remote.backup.version
        )

        let mergedEnvelope = SyncEnvelope(
            schemaVersion: SyncEnvelope.currentSchemaVersion,
            revision: remote.revision,
            deviceId: deviceId,
            deviceName: deviceName,
            updatedAt: now,
            tombstones: activeTombstones,
            backup: mergedBackup
        )

        let mergedSemantic = SyncSemanticState(
            backup: mergedBackup,
            tombstones: activeTombstones,
            includeSettings: includeSettings
        )
        let localSemantic = SyncSemanticState(
            backup: local.backup,
            tombstones: pruneTombstones(local.tombstones, olderThan: cutoffDate).canonicalized(),
            includeSettings: includeSettings
        )
        let remoteSemantic = SyncSemanticState(
            backup: remote.backup,
            tombstones: pruneTombstones(remote.tombstones, olderThan: cutoffDate).canonicalized(),
            includeSettings: includeSettings
        )

        let stats = SyncSnapshotStats.from(backup: mergedBackup)

        return SyncMergeResult(
            mergedEnvelope: mergedEnvelope,
            localNeedsApply: mergedSemantic != localSemantic,
            remoteNeedsUpload: mergedSemantic != remoteSemantic,
            stats: stats
        )
    }
}

extension SyncMerger {
    static func pruneTombstones(_ tombstones: SyncTombstones, olderThan cutoff: Date) -> SyncTombstones {
        SyncTombstones(
            libraryManga: tombstones.libraryManga.filter { $0.deletedAt >= cutoff },
            history: tombstones.history.filter { $0.deletedAt >= cutoff },
            mangaHistory: tombstones.mangaHistory.filter { $0.deletedAt >= cutoff },
            historyClearedAt: tombstones.historyClearedAt.flatMap { $0 >= cutoff ? $0 : nil },
            categories: tombstones.categories.filter { $0.deletedAt >= cutoff },
            tracks: tombstones.tracks.filter { $0.deletedAt >= cutoff },
            categoryUpserts: tombstones.categoryUpserts.filter { $0.updatedAt >= cutoff },
            trackUpserts: tombstones.trackUpserts.filter { $0.updatedAt >= cutoff },
            mangaCategoryUpdates: tombstones.mangaCategoryUpdates.filter { $0.updatedAt >= cutoff },
            mangaDetailsUpdates: tombstones.mangaDetailsUpdates.filter { $0.updatedAt >= cutoff },
            mangaFieldUpdates: tombstones.mangaFieldUpdates.filter { $0.updatedAt >= cutoff }
        )
    }

    static func settingsDigest(_ settings: [String: JSONAnyValue]?) -> String {
        let filtered = (settings ?? [:]).filter { isAllowedSyncSettingKey($0.key) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = (try? encoder.encode(filtered)) ?? Data()
        return SyncEnvelopeCodec.sha256Hex(data)
    }

    static func maxOptionalDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
            case let (.some(l), .some(r)):
                max(l, r)
            case let (.some(l), .none), let (.none, .some(l)):
                l
            case (.none, .none):
                nil
        }
    }
}

// MARK: - Step Helpers

private extension SyncMerger {
    struct MergeInputs {
        let local: SyncEnvelope
        let remote: SyncEnvelope
    }

    struct LibraryPairDates {
        let localCategoryDate: Date?
        let remoteCategoryDate: Date?
        let inputs: MergeInputs
        let activeCategoryTitles: Set<String>
        let reAddedAfterDelete: Bool
    }

    struct SessionFilterContext {
        let suppressedChapterDeletes: [ChapterIdentifier: Date]
        let mangaHistoryDeletes: [MangaIdentifier: Date]
        let historyClearedAt: Date?
    }

    static func mergeTombstones(local: SyncTombstones, remote: SyncTombstones) -> SyncTombstones {
        SyncTombstones(
            libraryManga: local.libraryManga + remote.libraryManga,
            history: local.history + remote.history,
            mangaHistory: local.mangaHistory + remote.mangaHistory,
            historyClearedAt: maxOptionalDate(local.historyClearedAt, remote.historyClearedAt),
            categories: local.categories + remote.categories,
            tracks: local.tracks + remote.tracks,
            categoryUpserts: local.categoryUpserts + remote.categoryUpserts,
            trackUpserts: local.trackUpserts + remote.trackUpserts,
            mangaCategoryUpdates: local.mangaCategoryUpdates + remote.mangaCategoryUpdates,
            mangaDetailsUpdates: local.mangaDetailsUpdates + remote.mangaDetailsUpdates,
            mangaFieldUpdates: local.mangaFieldUpdates + remote.mangaFieldUpdates
        ).canonicalized()
    }

    static func mergeCategories(
        inputs: MergeInputs,
        tombstones: inout SyncTombstones
    ) -> ([BackupCategory], Set<String>) {
        var localByTitle: [String: BackupCategory] = [:]
        for item in inputs.local.backup.categories ?? [] {
            guard let title = item.title, !title.isEmpty else { continue }
            localByTitle[title] = item
        }
        var remoteByTitle: [String: BackupCategory] = [:]
        for item in inputs.remote.backup.categories ?? [] {
            guard let title = item.title, !title.isEmpty else { continue }
            remoteByTitle[title] = item
        }

        let localUpsertDates = Dictionary(
            inputs.local.tombstones.categoryUpserts.map { ($0.title, $0.updatedAt) },
            uniquingKeysWith: max
        )
        let remoteUpsertDates = Dictionary(
            inputs.remote.tombstones.categoryUpserts.map { ($0.title, $0.updatedAt) },
            uniquingKeysWith: max
        )
        let upsertDates = Dictionary(
            tombstones.categoryUpserts.map { ($0.title, $0.updatedAt) },
            uniquingKeysWith: max
        )
        let deleteDates = Dictionary(
            tombstones.categories.map { ($0.title, $0.deletedAt) },
            uniquingKeysWith: max
        )

        let allTitles = Set(localByTitle.keys).union(remoteByTitle.keys)
        var surviving: [BackupCategory] = []
        var activeTitles = Set<String>()
        var staleDeletes = Set<String>()

        for title in allTitles.sorted() {
            let deletedAt = deleteDates[title]
            let upsertedAt = upsertDates[title]

            if let deletedAt {
                if let upsertedAt, upsertedAt > deletedAt {
                    staleDeletes.insert(title)
                } else {
                    continue
                }
            }

            let chosen: BackupCategory? = switch (localByTitle[title], remoteByTitle[title]) {
                case let (.some(lItem), .some(rItem)):
                    preferLocalTimestamp(
                        localItemDate: localUpsertDates[title],
                        remoteItemDate: remoteUpsertDates[title],
                        inputs: inputs
                    ) ? lItem : rItem
                case let (.some(lItem), .none):
                    lItem
                case let (.none, .some(rItem)):
                    rItem
                case (.none, .none):
                    nil
            }

            if let chosen {
                surviving.append(chosen)
                activeTitles.insert(title)
            }
        }

        if !staleDeletes.isEmpty {
            tombstones.categories.removeAll { staleDeletes.contains($0.title) }
        }

        let sorted = surviving.sorted {
            ($0.group ?? false ? 1 : 0, $0.sort ?? Int.max, $0.title ?? "")
                < ($1.group ?? false ? 1 : 0, $1.sort ?? Int.max, $1.title ?? "")
        }
        return (sorted, activeTitles)
    }

    static func mergeLibrary(
        inputs: MergeInputs,
        activeCategoryTitles: Set<String>,
        tombstones: inout SyncTombstones
    ) -> ([BackupLibraryManga], Set<MangaIdentifier>) {
        let localMap = Dictionary(
            (inputs.local.backup.library ?? []).map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let remoteMap = Dictionary(
            (inputs.remote.backup.library ?? []).map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let deleteMap = Dictionary(
            tombstones.libraryManga.map { ($0.mangaIdentifier, $0.deletedAt) },
            uniquingKeysWith: max
        )
        let localCatDates = Dictionary(
            inputs.local.tombstones.mangaCategoryUpdates.map { ($0.mangaIdentifier, $0.updatedAt) },
            uniquingKeysWith: max
        )
        let remoteCatDates = Dictionary(
            inputs.remote.tombstones.mangaCategoryUpdates.map { ($0.mangaIdentifier, $0.updatedAt) },
            uniquingKeysWith: max
        )

        let allIds = Set(localMap.keys).union(remoteMap.keys).union(deleteMap.keys)
        var merged: [BackupLibraryManga] = []
        var deletedIds = Set<MangaIdentifier>()
        var staleLibraryTombstones = Set<MangaIdentifier>()

        for id in allIds {
            let localItem = localMap[id]
            let remoteItem = remoteMap[id]
            let deletedAt = deleteMap[id]
            let pairDates = LibraryPairDates(
                localCategoryDate: localCatDates[id],
                remoteCategoryDate: remoteCatDates[id],
                inputs: inputs,
                activeCategoryTitles: activeCategoryTitles,
                reAddedAfterDelete: deletedAt != nil
            )

            if let deletedAt {
                let validLocal = localItem.flatMap { $0.dateAdded > deletedAt ? $0 : nil }
                let validRemote = remoteItem.flatMap { $0.dateAdded > deletedAt ? $0 : nil }

                if let entry = combineLibraryPair(local: validLocal, remote: validRemote, context: pairDates) {
                    merged.append(entry)
                    staleLibraryTombstones.insert(id)
                } else {
                    deletedIds.insert(id)
                }
            } else if let entry = combineLibraryPair(local: localItem, remote: remoteItem, context: pairDates) {
                merged.append(entry)
            }
        }

        if !staleLibraryTombstones.isEmpty {
            tombstones.libraryManga.removeAll { staleLibraryTombstones.contains($0.mangaIdentifier) }
        }

        let sorted = merged.sorted { ($0.sourceId, $0.mangaId) < ($1.sourceId, $1.mangaId) }
        return (sorted, deletedIds)
    }

    static func combineLibraryPair(
        local: BackupLibraryManga?,
        remote: BackupLibraryManga?,
        context: LibraryPairDates
    ) -> BackupLibraryManga? {
        switch (local, remote) {
            case let (.some(l), .some(r)):
                var combined = l
                combined.lastOpened = max(l.lastOpened, r.lastOpened)
                combined.lastUpdated = max(l.lastUpdated, r.lastUpdated)
                combined.lastUpdatedChapters = maxOptionalDate(l.lastUpdatedChapters, r.lastUpdatedChapters)
                combined.lastChapter = maxOptionalDate(l.lastChapter, r.lastChapter)
                combined.lastRead = maxOptionalDate(l.lastRead, r.lastRead)
                combined.dateAdded = context.reAddedAfterDelete ? max(l.dateAdded, r.dateAdded) : min(l.dateAdded, r.dateAdded)

                let lCats = (l.categories ?? []).filter { context.activeCategoryTitles.contains($0) }.sorted()
                let rCats = (r.categories ?? []).filter { context.activeCategoryTitles.contains($0) }.sorted()
                if context.localCategoryDate != nil || context.remoteCategoryDate != nil {
                    combined.categories = preferLocalTimestamp(
                        localItemDate: context.localCategoryDate,
                        remoteItemDate: context.remoteCategoryDate,
                        inputs: context.inputs
                    ) ? lCats : rCats
                } else {
                    combined.categories = Array(Set(lCats).union(rCats)).sorted()
                }
                return combined

            case let (.some(item), .none), let (.none, .some(item)):
                var copy = item
                if let categories = copy.categories {
                    copy.categories = Array(Set(categories.filter { context.activeCategoryTitles.contains($0) })).sorted()
                }
                return copy

            case (.none, .none):
                return nil
        }
    }

    static func mergeManga(
        inputs: MergeInputs,
        deletedLibraryIds: Set<MangaIdentifier>,
        mergedFieldUpdates: [SyncMangaFieldUpdate]
    ) -> [BackupManga] {
        let localLibMap = Dictionary(
            (inputs.local.backup.library ?? []).map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let remoteLibMap = Dictionary(
            (inputs.remote.backup.library ?? []).map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let localDetailsDates = Dictionary(
            inputs.local.tombstones.mangaDetailsUpdates.map { ($0.mangaIdentifier, $0.updatedAt) },
            uniquingKeysWith: max
        )
        let remoteDetailsDates = Dictionary(
            inputs.remote.tombstones.mangaDetailsUpdates.map { ($0.mangaIdentifier, $0.updatedAt) },
            uniquingKeysWith: max
        )
        let localFieldUpdates = Dictionary(
            inputs.local.tombstones.mangaFieldUpdates.map { ($0.fieldKey, $0) },
            uniquingKeysWith: { latestFieldUpdate($0, $1) }
        )
        let remoteFieldUpdates = Dictionary(
            inputs.remote.tombstones.mangaFieldUpdates.map { ($0.fieldKey, $0) },
            uniquingKeysWith: { latestFieldUpdate($0, $1) }
        )
        let mergedFieldMap = Dictionary(
            mergedFieldUpdates.map { ($0.fieldKey, $0) },
            uniquingKeysWith: { latestFieldUpdate($0, $1) }
        )
        let localMap = Dictionary(
            (inputs.local.backup.manga ?? []).map { (MangaIdentifier(sourceKey: $0.sourceId, mangaKey: $0.id), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let remoteMap = Dictionary(
            (inputs.remote.backup.manga ?? []).map { (MangaIdentifier(sourceKey: $0.sourceId, mangaKey: $0.id), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var result: [BackupManga] = []
        for id in Set(localMap.keys).union(remoteMap.keys) where !deletedLibraryIds.contains(id) {
            switch (localMap[id], remoteMap[id]) {
                case let (.some(lItem), .some(rItem)):
                    let lDate = maxOptionalDate(localDetailsDates[id], localLibMap[id]?.lastUpdated)
                    let rDate = maxOptionalDate(remoteDetailsDates[id], remoteLibMap[id]?.lastUpdated)
                    let preferLocal = preferLocalTimestamp(
                        localItemDate: lDate,
                        remoteItemDate: rDate,
                        inputs: inputs
                    )
                    let base = preferLocal ? lItem : rItem
                    let other = preferLocal ? rItem : lItem
                    let context = MangaFieldMergeContext(
                        id: id,
                        baseFieldUpdates: preferLocal ? localFieldUpdates : remoteFieldUpdates,
                        otherFieldUpdates: preferLocal ? remoteFieldUpdates : localFieldUpdates,
                        mergedFieldUpdates: mergedFieldMap
                    )
                    result.append(mergeMangaEntry(base: base, other: other, context: context))
                case let (.some(item), .none), let (.none, .some(item)):
                    result.append(item)
                case (.none, .none):
                    break
            }
        }
        return result.sorted { ($0.sourceId, $0.id) < ($1.sourceId, $1.id) }
    }

    struct MangaFieldMergeContext {
        let id: MangaIdentifier
        let baseFieldUpdates: [SyncMangaFieldKey: SyncMangaFieldUpdate]
        let otherFieldUpdates: [SyncMangaFieldKey: SyncMangaFieldUpdate]
        let mergedFieldUpdates: [SyncMangaFieldKey: SyncMangaFieldUpdate]
    }

    static func mergeMangaEntry(
        base: BackupManga,
        other: BackupManga,
        context: MangaFieldMergeContext
    ) -> BackupManga {
        let baseEdited = EditedKeys(rawValue: Int32(base.editedKeys ?? 0))
        let otherEdited = EditedKeys(rawValue: Int32(other.editedKeys ?? 0))
        var merged = base
        let knownBits = EditedKeys.allMetadataBitFlags.reduce(into: EditedKeys()) { $0.insert($1) }
        // Preserve any future upstream EditedKeys bits (>= 1 << 11) untouched across sync merges.
        var combinedEdited = baseEdited.union(otherEdited).subtracting(knownBits)

        for bit in EditedKeys.allMetadataBitFlags {
            let key = SyncMangaFieldKey(
                sourceId: context.id.sourceKey,
                mangaId: context.id.mangaKey,
                fieldBit: bit.rawValue
            )
            let decision = resolveEditedField(
                bit: bit,
                baseEdited: baseEdited,
                otherEdited: otherEdited,
                key: key,
                context: context
            )
            if decision.isEdited {
                combinedEdited.insert(bit)
            }
            if decision.copyFromOther {
                copyMangaField(bit, from: other, into: &merged)
            }
        }

        if combinedEdited.rawValue != 0 || base.editedKeys != nil || other.editedKeys != nil {
            merged.editedKeys = Int(combinedEdited.rawValue)
        }
        merged.nextUpdateTime = maxOptionalDate(base.nextUpdateTime, other.nextUpdateTime)
        return merged
    }

    static func latestFieldUpdate(_ lhs: SyncMangaFieldUpdate, _ rhs: SyncMangaFieldUpdate) -> SyncMangaFieldUpdate {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt ? lhs : rhs
        }
        return !lhs.isReset && rhs.isReset ? lhs : rhs
    }

    static func resolveEditedField(
        bit: EditedKeys,
        baseEdited: EditedKeys,
        otherEdited: EditedKeys,
        key: SyncMangaFieldKey,
        context: MangaFieldMergeContext
    ) -> (isEdited: Bool, copyFromOther: Bool) {
        let baseHasBit = baseEdited.contains(bit)
        let otherHasBit = otherEdited.contains(bit)
        let baseUpdate = context.baseFieldUpdates[key]
        let otherUpdate = context.otherFieldUpdates[key]
        let mergedUpdate = context.mergedFieldUpdates[key]

        if mergedUpdate?.isReset == true {
            return (false, baseHasBit && !otherHasBit)
        }

        if baseHasBit && otherHasBit {
            if let otherUpdate, !otherUpdate.isReset {
                if let baseUpdate, !baseUpdate.isReset {
                    return (true, otherUpdate.updatedAt > baseUpdate.updatedAt)
                }
                if baseUpdate == nil {
                    return (true, true)
                }
            }
            return (true, false)
        }

        if !baseHasBit && otherHasBit {
            return (true, true)
        }

        return (baseHasBit, false)
    }

    static func copyMangaField(_ bit: EditedKeys, from source: BackupManga, into target: inout BackupManga) {
        switch bit {
            case .title: target.title = source.title
            case .authors: target.author = source.author
            case .artists: target.artist = source.artist
            case .description: target.desc = source.desc
            case .tags: target.tags = source.tags
            case .cover: target.cover = source.cover
            case .url: target.url = source.url
            case .status: target.status = source.status
            case .contentRating: target.nsfw = source.nsfw
            case .viewer: target.viewer = source.viewer
            case .neverUpdate: target.neverUpdate = source.neverUpdate
            default: break
        }
    }

    static func mergeChapters(
        inputs: MergeInputs,
        deletedLibraryIds: Set<MangaIdentifier>
    ) -> [BackupChapter] {
        let localLibMap = Dictionary(
            (inputs.local.backup.library ?? []).map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let remoteLibMap = Dictionary(
            (inputs.remote.backup.library ?? []).map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let localMap = Dictionary(
            (inputs.local.backup.chapters ?? []).map {
                (ChapterIdentifier(sourceKey: $0.sourceId, mangaKey: $0.mangaId, chapterKey: $0.id), $0)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let remoteMap = Dictionary(
            (inputs.remote.backup.chapters ?? []).map {
                (ChapterIdentifier(sourceKey: $0.sourceId, mangaKey: $0.mangaId, chapterKey: $0.id), $0)
            },
            uniquingKeysWith: { first, _ in first }
        )

        var merged: [BackupChapter] = []
        for id in Set(localMap.keys).union(remoteMap.keys) where !deletedLibraryIds.contains(id.mangaIdentifier) {
            switch (localMap[id], remoteMap[id]) {
                case let (.some(lItem), .some(rItem)):
                    let lDate = localLibMap[id.mangaIdentifier]?.lastUpdatedChapters
                        ?? localLibMap[id.mangaIdentifier]?.lastUpdated
                    let rDate = remoteLibMap[id.mangaIdentifier]?.lastUpdatedChapters
                        ?? remoteLibMap[id.mangaIdentifier]?.lastUpdated
                    let preferLocal = preferLocalTimestamp(
                        localItemDate: lDate,
                        remoteItemDate: rDate,
                        inputs: inputs
                    )
                    merged.append(preferLocal ? lItem : rItem)
                case let (.some(item), .none), let (.none, .some(item)):
                    merged.append(item)
                case (.none, .none):
                    break
            }
        }
        return merged.sorted {
            ($0.sourceId, $0.mangaId, $0.sourceOrder, $0.id) < ($1.sourceId, $1.mangaId, $1.sourceOrder, $1.id)
        }
    }
}

private extension SyncMerger {
    static func mergeHistory(
        local: [BackupHistory],
        remote: [BackupHistory],
        tombstones: inout SyncTombstones
    ) -> ([BackupHistory], [ChapterIdentifier: Date]) {
        let localMap = Dictionary(
            local.map { (ChapterIdentifier(sourceKey: $0.sourceId, mangaKey: $0.mangaId, chapterKey: $0.chapterId), $0) },
            uniquingKeysWith: pickBetterHistory
        )
        let remoteMap = Dictionary(
            remote.map { (ChapterIdentifier(sourceKey: $0.sourceId, mangaKey: $0.mangaId, chapterKey: $0.chapterId), $0) },
            uniquingKeysWith: pickBetterHistory
        )
        let chapterDeletes = Dictionary(
            tombstones.history.map { ($0.chapterIdentifier, $0.deletedAt) },
            uniquingKeysWith: max
        )
        let mangaDeletes = Dictionary(
            tombstones.mangaHistory.map { ($0.mangaIdentifier, $0.deletedAt) },
            uniquingKeysWith: max
        )

        var merged: [BackupHistory] = []
        var suppressedDeletes: [ChapterIdentifier: Date] = [:]
        var staleChapterTombstones = Set<ChapterIdentifier>()

        for id in Set(localMap.keys).union(remoteMap.keys) {
            let candidate: BackupHistory? = switch (localMap[id], remoteMap[id]) {
                case let (.some(lhs), .some(rhs)):
                    pickBetterHistory(lhs, rhs)
                case let (.some(item), .none), let (.none, .some(item)):
                    item
                case (.none, .none):
                    nil
            }
            guard let winning = candidate else { continue }

            let effectiveDeletedAt = maxOptionalDate(
                maxOptionalDate(chapterDeletes[id], mangaDeletes[id.mangaIdentifier]),
                tombstones.historyClearedAt
            )

            if let effectiveDeletedAt, effectiveDeletedAt >= winning.dateRead {
                suppressedDeletes[id] = effectiveDeletedAt
                continue
            }

            if let chapterDelete = chapterDeletes[id], winning.dateRead > chapterDelete {
                staleChapterTombstones.insert(id)
            }
            merged.append(winning)
        }

        for (chapterId, deletedAt) in chapterDeletes where localMap[chapterId] == nil && remoteMap[chapterId] == nil {
            suppressedDeletes[chapterId] = max(suppressedDeletes[chapterId] ?? .distantPast, deletedAt)
        }

        if !staleChapterTombstones.isEmpty {
            tombstones.history.removeAll { staleChapterTombstones.contains($0.chapterIdentifier) }
        }

        let sorted = merged.sorted { ($0.sourceId, $0.mangaId, $0.chapterId) < ($1.sourceId, $1.mangaId, $1.chapterId) }
        return (sorted, suppressedDeletes)
    }

    private static func pickBetterHistory(_ lhs: BackupHistory, _ rhs: BackupHistory) -> BackupHistory {
        var winner: BackupHistory
        var loser: BackupHistory
        if lhs.dateRead != rhs.dateRead {
            if lhs.dateRead > rhs.dateRead {
                winner = lhs
                loser = rhs
            } else {
                winner = rhs
                loser = lhs
            }
        } else if lhs.completed != rhs.completed {
            if lhs.completed {
                winner = lhs
                loser = rhs
            } else {
                winner = rhs
                loser = lhs
            }
        } else if (lhs.progress ?? -1) >= (rhs.progress ?? -1) {
            winner = lhs
            loser = rhs
        } else {
            winner = rhs
            loser = lhs
        }

        if (winner.total ?? 0) <= 0, let loserTotal = loser.total, loserTotal > 0 {
            winner.total = loserTotal
        }
        return winner
    }

    private static func mergeReadingSessions(
        local: [BackupReadingSession],
        remote: [BackupReadingSession],
        filters: SessionFilterContext
    ) -> [BackupReadingSession] {
        var seen = Set<BackupReadingSession>()
        var result: [BackupReadingSession] = []

        for session in local + remote {
            guard session.endDate > session.startDate, session.pagesRead > 0 else { continue }
            let deletedAt = maxOptionalDate(
                maxOptionalDate(
                    filters.suppressedChapterDeletes[session.identifier],
                    filters.mangaHistoryDeletes[session.identifier.mangaIdentifier]
                ),
                filters.historyClearedAt
            )
            if let deletedAt, deletedAt >= session.endDate {
                continue
            }
            if seen.insert(session).inserted {
                result.append(session)
            }
        }

        return result.sorted {
            ($0.sourceId, $0.mangaId, $0.chapterId, $0.startDate, $0.endDate)
                < ($1.sourceId, $1.mangaId, $1.chapterId, $1.startDate, $1.endDate)
        }
    }

    private static func mergeUpdates(
        local: [BackupUpdate],
        remote: [BackupUpdate],
        deletedLibraryIds: Set<MangaIdentifier>
    ) -> [BackupUpdate] {
        var map: [ChapterIdentifier: BackupUpdate] = [:]
        for item in local + remote {
            let key = ChapterIdentifier(sourceKey: item.sourceId, mangaKey: item.mangaId, chapterKey: item.chapterId)
            guard !deletedLibraryIds.contains(key.mangaIdentifier) else { continue }
            if let existing = map[key] {
                var updated = existing
                updated.date = max(existing.date, item.date)
                updated.viewed = existing.viewed || item.viewed
                map[key] = updated
            } else {
                map[key] = item
            }
        }
        return map.values.sorted { ($0.sourceId, $0.mangaId, $0.chapterId) < ($1.sourceId, $1.mangaId, $1.chapterId) }
    }

    static func mergeTracks(
        inputs: MergeInputs,
        deletedLibraryIds: Set<MangaIdentifier>,
        tombstones: inout SyncTombstones
    ) -> [BackupTrackItem] {
        let localMap = Dictionary(
            (inputs.local.backup.trackItems ?? []).map { (SyncTrackKey(trackItem: $0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let remoteMap = Dictionary(
            (inputs.remote.backup.trackItems ?? []).map { (SyncTrackKey(trackItem: $0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let localUpsertDates = Dictionary(
            inputs.local.tombstones.trackUpserts.map { ($0.trackKey, $0.updatedAt) },
            uniquingKeysWith: max
        )
        let remoteUpsertDates = Dictionary(
            inputs.remote.tombstones.trackUpserts.map { ($0.trackKey, $0.updatedAt) },
            uniquingKeysWith: max
        )
        let deleteMap = Dictionary(tombstones.tracks.map { ($0.trackKey, $0.deletedAt) }, uniquingKeysWith: max)
        let upsertMap = Dictionary(tombstones.trackUpserts.map { ($0.trackKey, $0.updatedAt) }, uniquingKeysWith: max)

        var merged: [BackupTrackItem] = []
        var staleDeletes = Set<SyncTrackKey>()

        for key in Set(localMap.keys).union(remoteMap.keys) {
            let mangaId = MangaIdentifier(sourceKey: key.sourceId, mangaKey: key.mangaId)
            guard !deletedLibraryIds.contains(mangaId) else { continue }

            if let deletedAt = deleteMap[key] {
                if let upsertedAt = upsertMap[key], upsertedAt > deletedAt {
                    staleDeletes.insert(key)
                } else {
                    continue
                }
            }

            let chosen: BackupTrackItem? = switch (localMap[key], remoteMap[key]) {
                case let (.some(lItem), .some(rItem)):
                    preferLocalTimestamp(
                        localItemDate: localUpsertDates[key],
                        remoteItemDate: remoteUpsertDates[key],
                        inputs: inputs
                    ) ? lItem : rItem
                case let (.some(item), .none), let (.none, .some(item)):
                    item
                case (.none, .none):
                    nil
            }
            if let chosen {
                merged.append(chosen)
            }
        }

        if !staleDeletes.isEmpty {
            tombstones.tracks.removeAll { staleDeletes.contains($0.trackKey) }
        }

        return merged.sorted { ($0.trackerId, $0.sourceId, $0.mangaId, $0.id) < ($1.trackerId, $1.sourceId, $1.mangaId, $1.id) }
    }

    private static func mergeVocab(
        local: [BackupVocabEntry],
        remote: [BackupVocabEntry]
    ) -> [BackupVocabEntry] {
        struct Key: Hashable {
            let sourceId: String
            let mangaId: String
            let chapterId: String
            let word: String
            let reading: String
            let page: Int
            let createdDateMillis: Int64
        }

        var map: [Key: BackupVocabEntry] = [:]
        for item in local + remote {
            let key = Key(
                sourceId: item.sourceId,
                mangaId: item.mangaId,
                chapterId: item.chapterId,
                word: item.word,
                reading: item.reading ?? "",
                page: item.page,
                createdDateMillis: Int64((item.createdDate.timeIntervalSince1970 * 1000).rounded())
            )
            if map[key] == nil {
                map[key] = item
            }
        }
        return map.values.sorted {
            ($0.sourceId, $0.mangaId, $0.chapterId, $0.word, $0.createdDate)
                < ($1.sourceId, $1.mangaId, $1.chapterId, $1.word, $1.createdDate)
        }
    }

    private static func mergeSources(
        local: [BackupSource],
        remote: [BackupSource],
        inputs: MergeInputs
    ) -> [BackupSource] {
        var map: [String: BackupSource] = [:]
        let preferLocal = preferLocalEnvelope(local: inputs.local, remote: inputs.remote)
        let ordered = preferLocal ? (remote + local) : (local + remote)
        for item in ordered {
            if let existing = map[item.id] {
                if item.config != nil || existing.config == nil {
                    map[item.id] = item
                }
            } else {
                map[item.id] = item
            }
        }
        return map.values.sorted { $0.id < $1.id }
    }

    private static func mergeSourceLists(local: [String], remote: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for url in local + remote where seen.insert(url).inserted {
            result.append(url)
        }
        return result.sorted()
    }

    private static func mergeSettings(
        local: [String: JSONAnyValue]?,
        remote: [String: JSONAnyValue]?,
        inputs: MergeInputs,
        includeSettings: Bool,
        localSettingsModified: Bool?
    ) -> [String: JSONAnyValue]? {
        guard includeSettings else { return nil }
        var combined: [String: JSONAnyValue] = [:]
        let preferLocal: Bool = if let localSettingsModified {
            if !localSettingsModified {
                false
            } else if inputs.local.updatedAt != inputs.remote.updatedAt {
                inputs.local.updatedAt > inputs.remote.updatedAt
            } else {
                preferLocalEnvelope(local: inputs.local, remote: inputs.remote)
            }
        } else {
            preferLocalEnvelope(local: inputs.local, remote: inputs.remote)
        }
        let older = preferLocal ? (remote ?? [:]) : (local ?? [:])
        let newer = preferLocal ? (local ?? [:]) : (remote ?? [:])

        for (key, value) in older where isAllowedSyncSettingKey(key) {
            combined[key] = value
        }
        for (key, value) in newer where isAllowedSyncSettingKey(key) {
            combined[key] = value
        }
        return combined.isEmpty ? [:] : combined
    }

    static func preferLocalEnvelope(local: SyncEnvelope, remote: SyncEnvelope) -> Bool {
        if local.revision != remote.revision {
            return local.revision > remote.revision
        }
        if local.updatedAt != remote.updatedAt {
            return local.updatedAt > remote.updatedAt
        }
        return local.deviceId > remote.deviceId
    }

    static func preferLocalTimestamp(
        localItemDate: Date?,
        remoteItemDate: Date?,
        inputs: MergeInputs
    ) -> Bool {
        switch (localItemDate, remoteItemDate) {
            case let (.some(l), .some(r)):
                if l != r {
                    return l > r
                }
                return preferLocalEnvelope(local: inputs.local, remote: inputs.remote)
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return preferLocalEnvelope(local: inputs.local, remote: inputs.remote)
        }
    }
}

extension SyncMerger {
    static func isAllowedSyncSettingKey(_ key: String) -> Bool {
        guard !excludedSettingsKeys.contains(key) else { return false }
        guard !excludedSettingsPrefixes.contains(where: { key.hasPrefix($0) }) else { return false }
        let lower = key.lowercased()
        guard !sensitiveSettingsKeywords.contains(where: lower.contains) else { return false }
        return true
    }
}

// MARK: - Canonical Diff Representation

private struct SyncSemanticState: Equatable {
    struct RoundedDate: Equatable {
        let millis: Int64?

        init(_ date: Date?) {
            millis = date.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
        }
    }

    struct MangaDateKey: Equatable {
        let sourceId: String
        let mangaId: String
        let date: RoundedDate
    }

    struct ChapterDateKey: Equatable {
        let sourceId: String
        let mangaId: String
        let chapterId: String
        let date: RoundedDate
    }

    struct StringDateKey: Equatable {
        let value: String
        let date: RoundedDate
    }

    struct TrackDateKey: Equatable {
        let trackerId: String
        let sourceId: String
        let mangaId: String
        let date: RoundedDate
    }

    struct FieldUpdateKey: Equatable {
        let sourceId: String
        let mangaId: String
        let fieldBit: Int32
        let date: RoundedDate
        let isReset: Bool
    }

    struct TombstoneKey: Equatable {
        let library: [MangaDateKey]
        let history: [ChapterDateKey]
        let mangaHistory: [MangaDateKey]
        let historyClearedAt: RoundedDate
        let categories: [StringDateKey]
        let tracks: [TrackDateKey]
        let categoryUpserts: [StringDateKey]
        let trackUpserts: [TrackDateKey]
        let mangaCategoryUpdates: [MangaDateKey]
        let mangaDetailsUpdates: [MangaDateKey]
        let mangaFieldUpdates: [FieldUpdateKey]
    }

    struct LibraryKey: Equatable {
        let sourceId: String
        let mangaId: String
        let lastOpened: RoundedDate
        let lastUpdated: RoundedDate
        let lastUpdatedChapters: RoundedDate
        let lastChapter: RoundedDate
        let lastRead: RoundedDate
        let dateAdded: RoundedDate
        let categories: [String]
    }

    struct HistoryKey: Equatable {
        let sourceId: String
        let mangaId: String
        let chapterId: String
        let dateRead: RoundedDate
        let progress: Int?
        let total: Int?
        let completed: Bool
    }

    struct MangaKey: Equatable {
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
        let chapterFlags: Int?
        let langFilter: String?
        let scanlatorFilter: [String]?
        let editedKeys: Int?
    }

    struct SessionKey: Equatable {
        let sourceId: String
        let mangaId: String
        let chapterId: String
        let pagesRead: Int
        let startDate: RoundedDate
        let endDate: RoundedDate
    }

    struct UpdateKey: Equatable {
        let sourceId: String
        let mangaId: String
        let chapterId: String
        let date: RoundedDate
        let viewed: Bool
    }

    let library: [LibraryKey]
    let history: [HistoryKey]
    let manga: [MangaKey]
    let chapters: [BackupChapter]
    let trackItems: [BackupTrackItem]
    let readingSessions: [SessionKey]
    let vocabulary: [BackupVocabEntry]
    let updates: [UpdateKey]
    let categories: [BackupCategory]
    let sources: [BackupSource]
    let sourceLists: [String]
    let settings: [String: JSONAnyValue]?
    let tombstones: TombstoneKey

    init(backup: Backup, tombstones: SyncTombstones, includeSettings: Bool) {
        self.library = (backup.library ?? [])
            .map {
                LibraryKey(
                    sourceId: $0.sourceId,
                    mangaId: $0.mangaId,
                    lastOpened: RoundedDate($0.lastOpened),
                    lastUpdated: RoundedDate($0.lastUpdated),
                    lastUpdatedChapters: RoundedDate($0.lastUpdatedChapters),
                    lastChapter: RoundedDate($0.lastChapter),
                    lastRead: RoundedDate($0.lastRead),
                    dateAdded: RoundedDate($0.dateAdded),
                    categories: ($0.categories ?? []).sorted()
                )
            }
            .sorted { ($0.sourceId, $0.mangaId) < ($1.sourceId, $1.mangaId) }

        self.history = (backup.history ?? [])
            .map {
                HistoryKey(
                    sourceId: $0.sourceId,
                    mangaId: $0.mangaId,
                    chapterId: $0.chapterId,
                    dateRead: RoundedDate($0.dateRead),
                    progress: $0.progress,
                    total: $0.total,
                    completed: $0.completed
                )
            }
            .sorted { ($0.sourceId, $0.mangaId, $0.chapterId) < ($1.sourceId, $1.mangaId, $1.chapterId) }

        self.manga = (backup.manga ?? [])
            .map {
                MangaKey(
                    id: $0.id,
                    sourceId: $0.sourceId,
                    title: $0.title,
                    author: $0.author,
                    artist: $0.artist,
                    desc: $0.desc,
                    tags: $0.tags,
                    cover: $0.cover,
                    url: $0.url,
                    status: $0.status,
                    nsfw: $0.nsfw,
                    viewer: $0.viewer,
                    neverUpdate: $0.neverUpdate,
                    chapterFlags: $0.chapterFlags,
                    langFilter: $0.langFilter,
                    scanlatorFilter: $0.scanlatorFilter,
                    editedKeys: $0.editedKeys
                )
            }
            .sorted { ($0.sourceId, $0.id) < ($1.sourceId, $1.id) }

        self.chapters = (backup.chapters ?? [])
            .sorted { ($0.sourceId, $0.mangaId, $0.sourceOrder, $0.id) < ($1.sourceId, $1.mangaId, $1.sourceOrder, $1.id) }

        self.trackItems = (backup.trackItems ?? [])
            .sorted { ($0.trackerId, $0.sourceId, $0.mangaId, $0.id) < ($1.trackerId, $1.sourceId, $1.mangaId, $1.id) }

        self.readingSessions = (backup.readingSessions ?? [])
            .filter { $0.endDate > $0.startDate && $0.pagesRead > 0 }
            .map {
                SessionKey(
                    sourceId: $0.sourceId,
                    mangaId: $0.mangaId,
                    chapterId: $0.chapterId,
                    pagesRead: $0.pagesRead,
                    startDate: RoundedDate($0.startDate),
                    endDate: RoundedDate($0.endDate)
                )
            }
            .sorted {
                ($0.sourceId, $0.mangaId, $0.chapterId, $0.startDate.millis ?? 0, $0.endDate.millis ?? 0)
                    < ($1.sourceId, $1.mangaId, $1.chapterId, $1.startDate.millis ?? 0, $1.endDate.millis ?? 0)
            }

        self.vocabulary = (backup.vocabulary ?? [])
            .sorted {
                ($0.sourceId, $0.mangaId, $0.chapterId, $0.word, $0.reading ?? "", $0.createdDate)
                    < ($1.sourceId, $1.mangaId, $1.chapterId, $1.word, $1.reading ?? "", $1.createdDate)
            }

        self.updates = (backup.updates ?? [])
            .map {
                UpdateKey(
                    sourceId: $0.sourceId,
                    mangaId: $0.mangaId,
                    chapterId: $0.chapterId,
                    date: RoundedDate($0.date),
                    viewed: $0.viewed
                )
            }
            .sorted { ($0.sourceId, $0.mangaId, $0.chapterId) < ($1.sourceId, $1.mangaId, $1.chapterId) }

        self.categories = (backup.categories ?? [])
            .sorted {
                ($0.group ?? false ? 1 : 0, $0.sort ?? Int.max, $0.title ?? "")
                    < ($1.group ?? false ? 1 : 0, $1.sort ?? Int.max, $1.title ?? "")
            }

        self.sources = (backup.sources ?? []).sorted { $0.id < $1.id }
        self.sourceLists = (backup.sourceLists ?? []).sorted()

        if includeSettings {
            self.settings = (backup.settings ?? [:]).filter { SyncMerger.isAllowedSyncSettingKey($0.key) }
        } else {
            self.settings = nil
        }

        let canonicalTombstones = tombstones.canonicalized()
        self.tombstones = TombstoneKey(
            library: canonicalTombstones.libraryManga.map {
                MangaDateKey(sourceId: $0.sourceId, mangaId: $0.mangaId, date: RoundedDate($0.deletedAt))
            },
            history: canonicalTombstones.history.map {
                ChapterDateKey(
                    sourceId: $0.sourceId,
                    mangaId: $0.mangaId,
                    chapterId: $0.chapterId,
                    date: RoundedDate($0.deletedAt)
                )
            },
            mangaHistory: canonicalTombstones.mangaHistory.map {
                MangaDateKey(sourceId: $0.sourceId, mangaId: $0.mangaId, date: RoundedDate($0.deletedAt))
            },
            historyClearedAt: RoundedDate(canonicalTombstones.historyClearedAt),
            categories: canonicalTombstones.categories.map {
                StringDateKey(value: $0.title, date: RoundedDate($0.deletedAt))
            },
            tracks: canonicalTombstones.tracks.map {
                TrackDateKey(
                    trackerId: $0.trackerId,
                    sourceId: $0.sourceId,
                    mangaId: $0.mangaId,
                    date: RoundedDate($0.deletedAt)
                )
            },
            categoryUpserts: canonicalTombstones.categoryUpserts.map {
                StringDateKey(value: $0.title, date: RoundedDate($0.updatedAt))
            },
            trackUpserts: canonicalTombstones.trackUpserts.map {
                TrackDateKey(
                    trackerId: $0.trackerId,
                    sourceId: $0.sourceId,
                    mangaId: $0.mangaId,
                    date: RoundedDate($0.updatedAt)
                )
            },
            mangaCategoryUpdates: canonicalTombstones.mangaCategoryUpdates.map {
                MangaDateKey(sourceId: $0.sourceId, mangaId: $0.mangaId, date: RoundedDate($0.updatedAt))
            },
            mangaDetailsUpdates: canonicalTombstones.mangaDetailsUpdates.map {
                MangaDateKey(sourceId: $0.sourceId, mangaId: $0.mangaId, date: RoundedDate($0.updatedAt))
            },
            mangaFieldUpdates: canonicalTombstones.mangaFieldUpdates.map {
                FieldUpdateKey(
                    sourceId: $0.sourceId,
                    mangaId: $0.mangaId,
                    fieldBit: $0.fieldBit,
                    date: RoundedDate($0.updatedAt),
                    isReset: $0.isReset
                )
            }
        )
    }
}
