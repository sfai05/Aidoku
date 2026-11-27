//
//  SyncCoreDataApplier.swift
//  Aidoku
//

import CoreData
import UIKit

protocol SyncSnapshotSource: Sendable {
    func captureBackup(includeSettings: Bool) async -> Backup
    func currentSettingsDigest() async -> String?
}

extension SyncSnapshotSource {
    func currentSettingsDigest() async -> String? { nil }
}

protocol SyncSnapshotApplier: Sendable {
    func applyMerged(_ envelope: SyncEnvelope) async throws -> Bool
    func replaceAll(with envelope: SyncEnvelope) async throws
}

final class BackupManagerSnapshotSource: SyncSnapshotSource {
    func captureBackup(includeSettings: Bool) async -> Backup {
        await BackupManager.shared.createBackup(
            options: .init(
                automatic: true,
                libraryEntries: true,
                history: true,
                chapters: true,
                tracking: true,
                readingSessions: true,
                vocabulary: true,
                updates: true,
                categories: true,
                settings: includeSettings,
                sourceLists: true,
                sensitiveSettings: false
            )
        )
    }

    func currentSettingsDigest() async -> String? {
        let sourcePrefixes: [String] = await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.getSources(context: context)
                .compactMap(\.id)
                .map { "\($0)." }
        }
        let allSettings = UserDefaults.standard.dictionaryRepresentation()
        var converted: [String: JSONAnyValue] = [:]
        for (key, value) in allSettings {
            let matchesPrefix = BackupManager.allowedSettingsPrefixes.contains { key.hasPrefix($0) }
                || sourcePrefixes.contains { key.hasPrefix($0) }
            guard matchesPrefix, SyncMerger.isAllowedSyncSettingKey(key) else { continue }
            if let data = value as? Data {
                converted[key] = .data(data)
            } else if
                let number = value as? NSNumber,
                CFGetTypeID(number) == CFBooleanGetTypeID()
            {
                converted[key] = .bool(number.boolValue)
            } else if let str = value as? String {
                converted[key] = .string(str)
            } else if let int = value as? Int {
                converted[key] = .int(int)
            } else if let dbl = value as? Double {
                converted[key] = .double(dbl)
            } else if let bool = value as? Bool {
                converted[key] = .bool(bool)
            } else if let arr = value as? [String] {
                converted[key] = .array(arr)
            }
        }
        return SyncMerger.settingsDigest(converted)
    }
}

final class SyncCoreDataApplier: SyncSnapshotApplier {
    private let tombstoneStore: SyncTombstoneStore

    init(tombstoneStore: SyncTombstoneStore = .shared) {
        self.tombstoneStore = tombstoneStore
    }

    func applyMerged(_ envelope: SyncEnvelope) async throws -> Bool {
        tombstoneStore.beginSuspendRecording()
        defer { tombstoneStore.endSuspendRecording() }

        let outcome = try await CoreDataManager.shared.container.performBackgroundTask { context -> ApplyOutcome in
            var outcome = ApplyOutcome()
            let tombstones = envelope.tombstones
            let backup = envelope.backup

            var categoryMap = Self.mergeCategories(
                backup.categories ?? [],
                tombstones: tombstones.categories,
                context: context,
                didChange: &outcome.databaseChanged
            )

            let deletedLibraryIds = Self.reconcileDeletedLibraryManga(
                backup.library ?? [],
                tombstones: tombstones.libraryManga,
                context: context,
                didChange: &outcome.databaseChanged
            )

            let mangaMap = Self.mergeManga(
                backup.manga ?? [],
                deletedLibraryIds: deletedLibraryIds,
                context: context,
                didChange: &outcome.databaseChanged
            )

            Self.mergeLibrary(
                backup.library ?? [],
                mangaMap: mangaMap,
                categoryMap: &categoryMap,
                context: context,
                didChange: &outcome.databaseChanged
            )

            let historyMap = Self.mergeHistory(
                backup.history ?? [],
                tombstones: tombstones,
                context: context,
                didChange: &outcome.databaseChanged
            )

            let chapterMap = Self.mergeChapters(
                backup.chapters ?? [],
                links: ChapterLinkContext(
                    deletedLibraryIds: deletedLibraryIds,
                    mangaMap: mangaMap,
                    historyMap: historyMap
                ),
                context: context,
                didChange: &outcome.databaseChanged
            )

            Self.mergeReadingSessions(
                backup.readingSessions ?? [],
                historyMap: historyMap,
                tombstones: tombstones,
                context: context,
                didChange: &outcome.databaseChanged
            )

            Self.mergeUpdates(
                backup.updates ?? [],
                deletedLibraryIds: deletedLibraryIds,
                chapterMap: chapterMap,
                context: context,
                didChange: &outcome.databaseChanged
            )

            Self.mergeTracks(
                backup.trackItems ?? [],
                deletedLibraryIds: deletedLibraryIds,
                trackTombstones: tombstones.tracks,
                context: context,
                didChange: &outcome.databaseChanged
            )

            Self.mergeVocab(
                backup.vocabulary ?? [],
                context: context,
                didChange: &outcome.databaseChanged
            )

            outcome.sourcesChanged = Self.mergeCustomSources(
                backup.sources ?? [],
                context: context
            )
            if outcome.sourcesChanged {
                outcome.databaseChanged = true
            }

            if context.hasChanges {
                do {
                    try context.save()
                } catch {
                    throw SyncError.persistenceError("Failed to save merged sync data: \(error.localizedDescription)")
                }
            }
            return outcome
        }

        var anythingChanged = outcome.databaseChanged
        if outcome.sourcesChanged {
            await SourceManager.shared.reloadSources()
        }

        if let sourceLists = envelope.backup.sourceLists, !sourceLists.isEmpty {
            await SourceManager.shared.waitForSourceListsLoad()
            let existingURLs = Set(await SourceManager.shared.getSourceListURLs().map(\.absoluteString))
            for rawURL in sourceLists where !existingURLs.contains(rawURL) {
                guard let url = URL(string: rawURL) else { continue }
                let added = await SourceManager.shared.addSourceList(url: url, allowUnavailable: true)
                if added {
                    anythingChanged = true
                }
            }
        }

        if let settings = envelope.backup.settings {
            let appliedSettings = await applySafeSettings(settings, sources: envelope.backup.sources ?? [])
            if appliedSettings {
                anythingChanged = true
            }
        }

        if outcome.databaseChanged {
            await MainActor.run {
                NotificationCenter.default.post(name: .updateHistory, object: nil)
                NotificationCenter.default.post(name: .updateTrackers, object: nil)
                NotificationCenter.default.post(name: .updateCategories, object: nil)
                NotificationCenter.default.post(name: .updateLibrary, object: nil)
            }
        }

        return anythingChanged
    }

    func replaceAll(with envelope: SyncEnvelope) async throws {
        tombstoneStore.beginSuspendRecording()
        defer { tombstoneStore.endSuspendRecording() }

        let backup = envelope.backup
        let sourcesChanged = try await CoreDataManager.shared.container.performBackgroundTask { context -> Bool in
            Self.clearNonLocalEntities(context: context)

            var categoryMap: [String: CategoryObject] = [:]
            for item in backup.categories ?? [] {
                guard let title = item.title, !title.isEmpty else { continue }
                categoryMap[title] = item.toObject(context: context)
            }

            var mangaMap: [MangaIdentifier: MangaObject] = [:]
            for existingManga in CoreDataManager.shared.getManga(context: context) {
                mangaMap[existingManga.identifier] = existingManga
            }
            for item in backup.manga ?? [] {
                let key = MangaIdentifier(sourceKey: item.sourceId, mangaKey: item.id)
                if let existing = mangaMap[key] {
                    Self.updateMangaObject(existing, from: item)
                } else {
                    mangaMap[key] = item.toObject(context: context)
                }
            }

            for item in backup.library ?? [] {
                guard let manga = mangaMap[item.identifier] else { continue }
                let libraryObject = item.toObject(context: context)
                libraryObject.manga = manga
                if let categories = item.categories, !categories.isEmpty {
                    libraryObject.categories = NSSet(array: categories.compactMap { categoryMap[$0] })
                }
            }

            var historyMap: [ChapterIdentifier: HistoryObject] = [:]
            for item in backup.history ?? [] {
                let key = ChapterIdentifier(sourceKey: item.sourceId, mangaKey: item.mangaId, chapterKey: item.chapterId)
                historyMap[key] = item.toObject(context: context)
            }

            var chapterMap: [ChapterIdentifier: ChapterObject] = [:]
            for existingChapter in CoreDataManager.shared.getChapters(context: context) {
                chapterMap[existingChapter.identifier] = existingChapter
            }
            for item in backup.chapters ?? [] {
                let key = ChapterIdentifier(sourceKey: item.sourceId, mangaKey: item.mangaId, chapterKey: item.id)
                let chapterObject: ChapterObject
                if let existing = chapterMap[key] {
                    Self.updateChapterObject(existing, from: item)
                    chapterObject = existing
                } else {
                    chapterObject = item.toObject(context: context)
                    chapterMap[key] = chapterObject
                }
                chapterObject.manga = mangaMap[key.mangaIdentifier]
                chapterObject.history = historyMap[key]
            }

            for item in backup.readingSessions ?? [] {
                guard item.endDate > item.startDate, item.pagesRead > 0 else { continue }
                let session = item.toObject(context: context)
                session.history = historyMap[item.identifier]
            }

            for item in backup.updates ?? [] {
                let key = ChapterIdentifier(sourceKey: item.sourceId, mangaKey: item.mangaId, chapterKey: item.chapterId)
                let update = item.toObject(context: context)
                update.chapter = chapterMap[key]
            }

            for item in backup.vocabulary ?? [] {
                _ = item.toObject(context: context)
            }

            for item in backup.trackItems ?? [] {
                _ = item.toObject(context: context)
            }

            var customSourceChanged = false
            for item in backup.sources ?? [] where item.config != nil {
                CoreDataManager.shared.removeSource(key: item.id, context: context)
                _ = item.toObject(context: context)
                customSourceChanged = true
            }

            do {
                if context.hasChanges {
                    try context.save()
                }
            } catch {
                throw SyncError.persistenceError("Force Pull failed while saving Core Data: \(error.localizedDescription)")
            }
            return customSourceChanged
        }

        if sourcesChanged {
            await SourceManager.shared.reloadSources()
        }

        if let sourceLists = backup.sourceLists {
            await SourceManager.shared.waitForSourceListsLoad()
            await SourceManager.shared.clearSourceLists()
            for rawURL in sourceLists {
                guard let url = URL(string: rawURL) else { continue }
                _ = await SourceManager.shared.addSourceList(url: url, allowUnavailable: true)
            }
        }

        if let settings = backup.settings {
            _ = await applySafeSettings(settings, sources: backup.sources ?? [])
        }

        await MainActor.run {
            NotificationCenter.default.post(name: .updateHistory, object: nil)
            NotificationCenter.default.post(name: .updateTrackers, object: nil)
            NotificationCenter.default.post(name: .updateCategories, object: nil)
            NotificationCenter.default.post(name: .updateLibrary, object: nil)
        }
    }

    // MARK: - Settings Helper

    private func applySafeSettings(_ settings: [String: JSONAnyValue], sources: [BackupSource]) async -> Bool {
        let loadedSources = await SourceManager.shared.getSourceInfos(sorted: false)
        let sourcePrefixes = Set(loadedSources.map { "\($0.sourceId)." })
            .union(sources.compactMap { $0.config == nil ? nil : "\($0.id)." })

        var changed = false
        for (key, value) in settings {
            let hasAllowedPrefix = BackupManager.allowedSettingsPrefixes.contains { key.hasPrefix($0) }
                || sourcePrefixes.contains { key.hasPrefix($0) }
            guard
                hasAllowedPrefix,
                SyncMerger.isAllowedSyncSettingKey(key)
            else {
                continue
            }
            UserDefaults.standard.set(value.toRaw(), forKey: key)
            changed = true
        }
        return changed
    }
}

// MARK: - Core Data Merge Subroutines

private extension SyncCoreDataApplier {
    struct ApplyOutcome {
        var databaseChanged = false
        var sourcesChanged = false
    }

    static func mergeCategories(
        _ mergedCategories: [BackupCategory],
        tombstones: [SyncCategoryTombstone],
        context: NSManagedObjectContext,
        didChange: inout Bool
    ) -> [String: CategoryObject] {
        var existingByTitle: [String: CategoryObject] = [:]
        for object in CoreDataManager.shared.getCategories(sorted: false, context: context) {
            if let title = object.title, !title.isEmpty {
                if existingByTitle[title] != nil {
                    context.delete(object)
                    didChange = true
                } else {
                    existingByTitle[title] = object
                }
            }
        }

        let mergedTitles = Set(mergedCategories.compactMap(\.title))
        for tombstone in tombstones where !mergedTitles.contains(tombstone.title) {
            if let existing = existingByTitle.removeValue(forKey: tombstone.title) {
                context.delete(existing)
                didChange = true
            }
        }

        for item in mergedCategories {
            guard let title = item.title, !title.isEmpty else { continue }
            if let existing = existingByTitle[title] {
                let targetSort = Int16(item.sort ?? Int(existing.sort))
                let targetGroup = item.group ?? existing.group
                let targetData = item.data ?? (existing.data as? Data)
                if existing.sort != targetSort || existing.group != targetGroup || (existing.data as? Data) != targetData {
                    existing.sort = targetSort
                    existing.group = targetGroup
                    existing.data = targetData as NSData?
                    didChange = true
                }
            } else {
                existingByTitle[title] = item.toObject(context: context)
                didChange = true
            }
        }

        return existingByTitle
    }

    static func reconcileDeletedLibraryManga(
        _ mergedLibrary: [BackupLibraryManga],
        tombstones: [SyncMangaTombstone],
        context: NSManagedObjectContext,
        didChange: inout Bool
    ) -> Set<MangaIdentifier> {
        let mergedIds = Set(mergedLibrary.map(\.identifier))
        var deletedIds = Set<MangaIdentifier>()

        for tombstone in tombstones {
            let mangaId = tombstone.mangaIdentifier
            guard !mergedIds.contains(mangaId) else { continue }
            deletedIds.insert(mangaId)

            if let libraryObject = CoreDataManager.shared.getLibraryManga(mangaId: mangaId, context: context) {
                if let mangaObject = libraryObject.manga, mangaObject.fileInfo == nil {
                    context.delete(mangaObject)
                } else {
                    context.delete(libraryObject)
                }
                CoreDataManager.shared.removeChapters(mangaId: mangaId, context: context)
                CoreDataManager.shared.removeTracks(mangaId: mangaId, context: context)
                didChange = true
            }
        }
        return deletedIds
    }

    static func mergeManga(
        _ mergedManga: [BackupManga],
        deletedLibraryIds: Set<MangaIdentifier>,
        context: NSManagedObjectContext,
        didChange: inout Bool
    ) -> [MangaIdentifier: MangaObject] {
        var map: [MangaIdentifier: MangaObject] = [:]
        for object in CoreDataManager.shared.getManga(context: context) {
            map[object.identifier] = object
        }

        for item in mergedManga {
            let id = MangaIdentifier(sourceKey: item.sourceId, mangaKey: item.id)
            guard !deletedLibraryIds.contains(id) else { continue }
            if let existing = map[id] {
                if updateMangaObject(existing, from: item) {
                    didChange = true
                }
            } else {
                map[id] = item.toObject(context: context)
                didChange = true
            }
        }

        return map
    }

    @discardableResult
    static func updateMangaObject(_ object: MangaObject, from item: BackupManga) -> Bool {
        var changed = false
        let newStatus = Int16(item.status)
        let newNsfw = Int16(item.nsfw)
        let newViewer = Int16(item.viewer)
        let newNeverUpdate = item.neverUpdate ?? false
        let newChapterFlags = Int16(item.chapterFlags ?? 0)
        let newEditedKeys = Int32(item.editedKeys ?? 0)

        if object.title != item.title { object.title = item.title; changed = true }
        if object.author != item.author { object.author = item.author; changed = true }
        if object.artist != item.artist { object.artist = item.artist; changed = true }
        if object.desc != item.desc { object.desc = item.desc; changed = true }
        if object.tags != item.tags { object.tags = item.tags; changed = true }
        if object.cover != item.cover { object.cover = item.cover; changed = true }
        if object.url != item.url { object.url = item.url; changed = true }
        if object.status != newStatus { object.status = newStatus; changed = true }
        if object.nsfw != newNsfw { object.nsfw = newNsfw; changed = true }
        if object.viewer != newViewer { object.viewer = newViewer; changed = true }
        if object.neverUpdate != newNeverUpdate { object.neverUpdate = newNeverUpdate; changed = true }
        if object.nextUpdateTime != item.nextUpdateTime { object.nextUpdateTime = item.nextUpdateTime; changed = true }
        if object.chapterFlags != newChapterFlags { object.chapterFlags = newChapterFlags; changed = true }
        if object.langFilter != item.langFilter { object.langFilter = item.langFilter; changed = true }
        if object.scanlatorFilter != item.scanlatorFilter { object.scanlatorFilter = item.scanlatorFilter; changed = true }
        if object.editedKeys != newEditedKeys { object.editedKeys = newEditedKeys; changed = true }

        return changed
    }

    static func mergeLibrary(
        _ mergedLibrary: [BackupLibraryManga],
        mangaMap: [MangaIdentifier: MangaObject],
        categoryMap: inout [String: CategoryObject],
        context: NSManagedObjectContext,
        didChange: inout Bool
    ) {
        var existingByKey: [MangaIdentifier: LibraryMangaObject] = [:]
        for object in CoreDataManager.shared.getLibraryManga(context: context) {
            guard let id = object.manga?.identifier else { continue }
            existingByKey[id] = object
        }

        for item in mergedLibrary {
            guard let mangaObject = mangaMap[item.identifier] else { continue }

            var targetCategories: [CategoryObject] = []
            for title in item.categories ?? [] where !title.isEmpty {
                if let existingCategory = categoryMap[title] {
                    targetCategories.append(existingCategory)
                } else {
                    let created = CategoryObject(context: context)
                    created.title = title
                    created.sort = Int16(categoryMap.count)
                    created.group = false
                    categoryMap[title] = created
                    targetCategories.append(created)
                    didChange = true
                }
            }

            if let existing = existingByKey[item.identifier] {
                if existing.lastOpened != item.lastOpened { existing.lastOpened = item.lastOpened; didChange = true }
                if existing.lastUpdated != item.lastUpdated { existing.lastUpdated = item.lastUpdated; didChange = true }
                let targetUpdatedChapters = item.lastUpdatedChapters ?? item.lastUpdated
                if existing.lastUpdatedChapters != targetUpdatedChapters {
                    existing.lastUpdatedChapters = targetUpdatedChapters
                    didChange = true
                }
                if existing.lastChapter != item.lastChapter { existing.lastChapter = item.lastChapter; didChange = true }
                if existing.lastRead != item.lastRead { existing.lastRead = item.lastRead; didChange = true }
                if existing.dateAdded != item.dateAdded { existing.dateAdded = item.dateAdded; didChange = true }

                let currentTitles = Set((existing.categories?.allObjects as? [CategoryObject])?.compactMap(\.title) ?? [])
                let newTitles = Set(targetCategories.compactMap(\.title))
                if currentTitles != newTitles {
                    existing.categories = NSSet(array: targetCategories)
                    didChange = true
                }
            } else {
                let created = item.toObject(context: context)
                created.manga = mangaObject
                created.categories = NSSet(array: targetCategories)
                existingByKey[item.identifier] = created
                didChange = true
            }
        }
    }

    static func mergeHistory(
        _ mergedHistory: [BackupHistory],
        tombstones: SyncTombstones,
        context: NSManagedObjectContext,
        didChange: inout Bool
    ) -> [ChapterIdentifier: HistoryObject] {
        var map: [ChapterIdentifier: HistoryObject] = [:]
        for object in CoreDataManager.shared.getHistory(context: context) {
            map[object.identifier] = object
        }

        let mergedIds = Set(
            mergedHistory.map { ChapterIdentifier(sourceKey: $0.sourceId, mangaKey: $0.mangaId, chapterKey: $0.chapterId) }
        )
        let chapterDeletes = Dictionary(tombstones.history.map { ($0.chapterIdentifier, $0.deletedAt) }, uniquingKeysWith: max)
        let mangaDeletes = Dictionary(tombstones.mangaHistory.map { ($0.mangaIdentifier, $0.deletedAt) }, uniquingKeysWith: max)

        for (id, existing) in map where !mergedIds.contains(id) {
            let deletedAt = maxDate(
                maxDate(chapterDeletes[id], mangaDeletes[id.mangaIdentifier]),
                tombstones.historyClearedAt
            )
            if let deletedAt, (existing.dateRead ?? .distantPast) <= deletedAt {
                context.delete(existing)
                map.removeValue(forKey: id)
                didChange = true
            }
        }

        for item in mergedHistory {
            let key = ChapterIdentifier(sourceKey: item.sourceId, mangaKey: item.mangaId, chapterKey: item.chapterId)
            let targetProgress = Int16(item.progress ?? -1)
            let targetTotal = Int16(item.total ?? 0)
            if let existing = map[key] {
                if existing.dateRead != item.dateRead
                    || existing.progress != targetProgress
                    || existing.total != targetTotal
                    || existing.completed != item.completed
                {
                    existing.dateRead = item.dateRead
                    existing.progress = targetProgress
                    existing.total = targetTotal
                    existing.completed = item.completed
                    didChange = true
                }
            } else {
                map[key] = item.toObject(context: context)
                didChange = true
            }
        }

        return map
    }

    struct ChapterLinkContext {
        let deletedLibraryIds: Set<MangaIdentifier>
        let mangaMap: [MangaIdentifier: MangaObject]
        let historyMap: [ChapterIdentifier: HistoryObject]
    }

    static func mergeChapters(
        _ mergedChapters: [BackupChapter],
        links: ChapterLinkContext,
        context: NSManagedObjectContext,
        didChange: inout Bool
    ) -> [ChapterIdentifier: ChapterObject] {
        var map: [ChapterIdentifier: ChapterObject] = [:]
        for object in CoreDataManager.shared.getChapters(context: context) {
            map[object.identifier] = object
        }

        for item in mergedChapters {
            let key = ChapterIdentifier(sourceKey: item.sourceId, mangaKey: item.mangaId, chapterKey: item.id)
            guard !links.deletedLibraryIds.contains(key.mangaIdentifier) else { continue }

            let chapterObject: ChapterObject
            if let existing = map[key] {
                if updateChapterObject(existing, from: item) {
                    didChange = true
                }
                chapterObject = existing
            } else {
                chapterObject = item.toObject(context: context)
                map[key] = chapterObject
                didChange = true
            }

            if chapterObject.manga !== links.mangaMap[key.mangaIdentifier], let targetManga = links.mangaMap[key.mangaIdentifier] {
                chapterObject.manga = targetManga
                didChange = true
            }
            if chapterObject.history !== links.historyMap[key], let targetHistory = links.historyMap[key] {
                chapterObject.history = targetHistory
                didChange = true
            }
        }

        return map
    }
}

private extension SyncCoreDataApplier {
    @discardableResult
    static func updateChapterObject(_ object: ChapterObject, from item: BackupChapter) -> Bool {
        var changed = false
        let newChapter = item.chapter.map { NSNumber(value: $0) }
        let newVolume = item.volume.map { NSNumber(value: $0) }
        let newLocked = item.locked ?? false
        let newOrder = Int16(item.sourceOrder)

        if object.title != item.title { object.title = item.title; changed = true }
        if object.scanlator != item.scanlator { object.scanlator = item.scanlator; changed = true }
        if object.url != item.url { object.url = item.url; changed = true }
        if object.lang != item.lang { object.lang = item.lang; changed = true }
        if object.chapter != newChapter { object.chapter = newChapter; changed = true }
        if object.volume != newVolume { object.volume = newVolume; changed = true }
        if object.dateUploaded != item.dateUploaded { object.dateUploaded = item.dateUploaded; changed = true }
        if object.thumbnail != item.thumbnail { object.thumbnail = item.thumbnail; changed = true }
        if object.locked != newLocked { object.locked = newLocked; changed = true }
        if object.sourceOrder != newOrder { object.sourceOrder = newOrder; changed = true }

        return changed
    }

    static func mergeReadingSessions(
        _ mergedSessions: [BackupReadingSession],
        historyMap: [ChapterIdentifier: HistoryObject],
        tombstones: SyncTombstones,
        context: NSManagedObjectContext,
        didChange: inout Bool
    ) {
        struct SessionKey: Hashable {
            let chapterId: ChapterIdentifier
            let startMillis: Int64
            let endMillis: Int64
            let pagesRead: Int
        }

        let chapterDeletes = Dictionary(tombstones.history.map { ($0.chapterIdentifier, $0.deletedAt) }, uniquingKeysWith: max)
        let mangaDeletes = Dictionary(tombstones.mangaHistory.map { ($0.mangaIdentifier, $0.deletedAt) }, uniquingKeysWith: max)

        var existingKeys = Set<SessionKey>()
        for object in CoreDataManager.shared.getSessions(context: context) {
            guard
                let startDate = object.startDate,
                let endDate = object.endDate
            else {
                continue
            }
            let chapterId = object.history?.identifier
            let deletedAt = maxDate(
                maxDate(chapterId.flatMap { chapterDeletes[$0] }, chapterId.flatMap { mangaDeletes[$0.mangaIdentifier] }),
                tombstones.historyClearedAt
            )
            if let deletedAt, endDate <= deletedAt {
                context.delete(object)
                didChange = true
                continue
            }
            guard let chapterId else { continue }
            existingKeys.insert(
                SessionKey(
                    chapterId: chapterId,
                    startMillis: Int64((startDate.timeIntervalSince1970 * 1000).rounded()),
                    endMillis: Int64((endDate.timeIntervalSince1970 * 1000).rounded()),
                    pagesRead: Int(object.pagesRead)
                )
            )
        }

        for item in mergedSessions {
            guard item.endDate > item.startDate, item.pagesRead > 0 else { continue }
            let key = SessionKey(
                chapterId: item.identifier,
                startMillis: Int64((item.startDate.timeIntervalSince1970 * 1000).rounded()),
                endMillis: Int64((item.endDate.timeIntervalSince1970 * 1000).rounded()),
                pagesRead: item.pagesRead
            )
            if existingKeys.insert(key).inserted {
                let session = item.toObject(context: context)
                session.history = historyMap[item.identifier]
                didChange = true
            }
        }
    }

    static func mergeUpdates(
        _ mergedUpdates: [BackupUpdate],
        deletedLibraryIds: Set<MangaIdentifier>,
        chapterMap: [ChapterIdentifier: ChapterObject],
        context: NSManagedObjectContext,
        didChange: inout Bool
    ) {
        var existingByKey: [ChapterIdentifier: MangaUpdateObject] = [:]
        for object in CoreDataManager.shared.getUpdates(context: context) {
            let key = object.identifier
            if deletedLibraryIds.contains(key.mangaIdentifier) {
                context.delete(object)
                didChange = true
            } else {
                existingByKey[key] = object
            }
        }

        for item in mergedUpdates {
            let key = ChapterIdentifier(sourceKey: item.sourceId, mangaKey: item.mangaId, chapterKey: item.chapterId)
            guard !deletedLibraryIds.contains(key.mangaIdentifier) else { continue }

            if let existing = existingByKey[key] {
                if existing.date != item.date || existing.viewed != item.viewed {
                    existing.date = max(existing.date ?? .distantPast, item.date)
                    existing.viewed = existing.viewed || item.viewed
                    didChange = true
                }
            } else {
                let created = item.toObject(context: context)
                created.chapter = chapterMap[key]
                existingByKey[key] = created
                didChange = true
            }
        }
    }

    static func mergeTracks(
        _ mergedTracks: [BackupTrackItem],
        deletedLibraryIds: Set<MangaIdentifier>,
        trackTombstones: [SyncTrackTombstone],
        context: NSManagedObjectContext,
        didChange: inout Bool
    ) {
        var existingByKey: [SyncTrackKey: TrackObject] = [:]
        for object in CoreDataManager.shared.getTracks(context: context) {
            let key = SyncTrackKey(
                trackerId: object.trackerId ?? "",
                sourceId: object.sourceId ?? "",
                mangaId: object.mangaId ?? ""
            )
            existingByKey[key] = object
        }

        let mergedKeys = Set(mergedTracks.map { SyncTrackKey(trackItem: $0) })
        for tombstone in trackTombstones where !mergedKeys.contains(tombstone.trackKey) {
            if let existing = existingByKey.removeValue(forKey: tombstone.trackKey) {
                context.delete(existing)
                didChange = true
            }
        }

        for item in mergedTracks {
            let mangaId = MangaIdentifier(sourceKey: item.sourceId, mangaKey: item.mangaId)
            guard !deletedLibraryIds.contains(mangaId) else { continue }
            let key = SyncTrackKey(trackItem: item)
            let newOffset = Int16(item.chapterOffset ?? 0)
            if let existing = existingByKey[key] {
                if existing.id != item.id || existing.title != item.title || existing.chapterOffset != newOffset {
                    existing.id = item.id
                    existing.title = item.title
                    existing.chapterOffset = newOffset
                    didChange = true
                }
            } else {
                existingByKey[key] = item.toObject(context: context)
                didChange = true
            }
        }
    }

    static func mergeVocab(
        _ mergedVocab: [BackupVocabEntry],
        context: NSManagedObjectContext,
        didChange: inout Bool
    ) {
        struct VocabKey: Hashable {
            let sourceId: String
            let mangaId: String
            let chapterId: String
            let word: String
            let reading: String
            let page: Int
            let createdDateMillis: Int64
        }

        var existingKeys = Set<VocabKey>()
        for object in CoreDataManager.shared.getVocab(sorted: false, context: context) {
            guard
                let sourceId = object.sourceId,
                let mangaId = object.mangaId,
                let chapterId = object.chapterId,
                let word = object.word,
                let createdDate = object.createdDate
            else {
                continue
            }
            existingKeys.insert(
                VocabKey(
                    sourceId: sourceId,
                    mangaId: mangaId,
                    chapterId: chapterId,
                    word: word,
                    reading: object.reading ?? "",
                    page: Int(object.page),
                    createdDateMillis: Int64((createdDate.timeIntervalSince1970 * 1000).rounded())
                )
            )
        }

        for item in mergedVocab {
            let key = VocabKey(
                sourceId: item.sourceId,
                mangaId: item.mangaId,
                chapterId: item.chapterId,
                word: item.word,
                reading: item.reading ?? "",
                page: item.page,
                createdDateMillis: Int64((item.createdDate.timeIntervalSince1970 * 1000).rounded())
            )
            if existingKeys.insert(key).inserted {
                _ = item.toObject(context: context)
                didChange = true
            }
        }
    }

    static func mergeCustomSources(_ mergedSources: [BackupSource], context: NSManagedObjectContext) -> Bool {
        var existingById: [String: SourceObject] = [:]
        for object in CoreDataManager.shared.getSources(context: context) {
            if let id = object.id {
                existingById[id] = object
            }
        }

        var sourcesChanged = false
        for item in mergedSources where item.config != nil {
            if let existing = existingById[item.id] {
                if (existing.customSource as? Data) != item.config || existing.apiVersion != item.apiVersion {
                    existing.apiVersion = item.apiVersion ?? existing.apiVersion
                    existing.customSource = item.config as NSObject?
                    sourcesChanged = true
                }
            } else if item.toObject(context: context) != nil {
                sourcesChanged = true
            }
        }
        return sourcesChanged
    }

    static func clearNonLocalEntities(context: NSManagedObjectContext) {
        CoreDataManager.shared.queueClear(request: CategoryObject.fetchRequest(), context: context)
        CoreDataManager.shared.queueClear(request: LibraryMangaObject.fetchRequest(), context: context)
        CoreDataManager.shared.queueClear(request: HistoryObject.fetchRequest(), context: context)
        CoreDataManager.shared.queueClear(request: ReadingSessionObject.fetchRequest(), context: context)
        CoreDataManager.shared.queueClear(request: MangaUpdateObject.fetchRequest(), context: context)
        CoreDataManager.shared.queueClear(request: TrackObject.fetchRequest(), context: context)
        CoreDataManager.shared.queueClear(request: VocabObject.fetchRequest(), context: context)

        for chapter in CoreDataManager.shared.getChapters(context: context) where chapter.fileInfo == nil {
            context.delete(chapter)
        }
        for manga in CoreDataManager.shared.getManga(context: context) {
            if manga.fileInfo != nil {
                if let libraryObject = manga.libraryObject {
                    context.delete(libraryObject)
                }
            } else {
                context.delete(manga)
            }
        }
        for source in CoreDataManager.shared.getSources(context: context) where source.customSource != nil {
            context.delete(source)
        }
    }

    static func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
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
