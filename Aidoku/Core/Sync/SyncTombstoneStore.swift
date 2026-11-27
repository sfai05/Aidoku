//
//  SyncTombstoneStore.swift
//  Aidoku
//

import CoreData
import Foundation

final class SyncTombstoneStore: @unchecked Sendable {
    static let shared = SyncTombstoneStore()

    private struct PersistedState: Codable {
        var tombstones: SyncTombstones
        var hasPendingLocalChanges: Bool
        var lastMutationAt: Date?
    }

    private let fileURL: URL
    private let lock = NSLock()
    private let nowProvider: @Sendable () -> Date
    private let recordingEnabledProvider: @Sendable () -> Bool
    private var loadedState: PersistedState?
    private var suspensionDepth = 0
    private var mutationEpoch: UInt64 = 0
    private var dirtyInMemory = false
    private var lastDiskSaveAt: Date?

    init(
        fileURL: URL = FileManager.default.applicationSupportDirectory
            .appendingPathComponent("ForkSync", isDirectory: true)
            .appendingPathComponent("sync_tombstones.json"),
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        recordingEnabledProvider: @escaping @Sendable () -> Bool = {
            UserDefaults.standard.bool(forKey: SyncConfiguration.Key.enabled)
        }
    ) {
        self.fileURL = fileURL
        self.nowProvider = nowProvider
        self.recordingEnabledProvider = recordingEnabledProvider
    }

    var isRecordingActive: Bool {
        guard recordingEnabledProvider() else { return false }
        lock.lock()
        defer { lock.unlock() }
        return suspensionDepth == 0
    }

    func beginSuspendRecording() {
        lock.lock()
        suspensionDepth += 1
        lock.unlock()
    }

    func endSuspendRecording() {
        lock.lock()
        suspensionDepth = max(0, suspensionDepth - 1)
        lock.unlock()
    }

    func withRecordingSuspended<T>(_ body: () throws -> T) rethrows -> T {
        beginSuspendRecording()
        defer { endSuspendRecording() }
        return try body()
    }

    struct Snapshot: Sendable {
        let tombstones: SyncTombstones
        let hasPendingChanges: Bool
        let epoch: UInt64
        let lastMutationAt: Date?
    }

    func snapshot() -> (tombstones: SyncTombstones, hasPendingChanges: Bool) {
        let state = snapshotWithEpoch()
        return (state.tombstones, state.hasPendingChanges)
    }

    func snapshotWithEpoch() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let state = loadStateLocked()
        return Snapshot(
            tombstones: state.tombstones.canonicalized(),
            hasPendingChanges: state.hasPendingLocalChanges,
            epoch: mutationEpoch,
            lastMutationAt: state.lastMutationAt
        )
    }

    func flushPendingToDisk() {
        lock.lock()
        defer { lock.unlock() }
        guard dirtyInMemory, let state = loadedState else { return }
        saveStateLocked(state)
    }

    func replaceTombstones(
        _ tombstones: SyncTombstones,
        clearPendingChanges: Bool,
        expectedEpoch: UInt64? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        var state = loadStateLocked()
        if let expectedEpoch, mutationEpoch != expectedEpoch {
            let merged = SyncTombstones(
                libraryManga: tombstones.libraryManga + state.tombstones.libraryManga,
                history: tombstones.history + state.tombstones.history,
                mangaHistory: tombstones.mangaHistory + state.tombstones.mangaHistory,
                historyClearedAt: SyncMerger.maxOptionalDate(
                    tombstones.historyClearedAt,
                    state.tombstones.historyClearedAt
                ),
                categories: tombstones.categories + state.tombstones.categories,
                tracks: tombstones.tracks + state.tombstones.tracks,
                categoryUpserts: tombstones.categoryUpserts + state.tombstones.categoryUpserts,
                trackUpserts: tombstones.trackUpserts + state.tombstones.trackUpserts,
                mangaCategoryUpdates: tombstones.mangaCategoryUpdates + state.tombstones.mangaCategoryUpdates,
                mangaDetailsUpdates: tombstones.mangaDetailsUpdates + state.tombstones.mangaDetailsUpdates,
                mangaFieldUpdates: tombstones.mangaFieldUpdates + state.tombstones.mangaFieldUpdates
            ).canonicalized()
            state.tombstones = merged
        } else {
            state.tombstones = tombstones.canonicalized()
            if clearPendingChanges {
                state.hasPendingLocalChanges = false
                state.lastMutationAt = nil
            }
        }
        saveStateLocked(state)
    }

    func markPendingLocalChanges(at date: Date? = nil) {
        mutateIfActive(at: date) { state, timestamp in
            state.hasPendingLocalChanges = true
            state.lastMutationAt = max(state.lastMutationAt ?? .distantPast, timestamp)
        }
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        loadedState = PersistedState(tombstones: .empty, hasPendingLocalChanges: false, lastMutationAt: nil)
        dirtyInMemory = false
        lastDiskSaveAt = nil
        fileURL.removeItem()
    }

    // MARK: - Domain Mutations

    func recordLibraryAddition(mangaId: MangaIdentifier, at date: Date? = nil) {
        mutateIfActive(at: date) { state, timestamp in
            state.tombstones.libraryManga.removeAll {
                $0.mangaIdentifier == mangaId && $0.deletedAt < timestamp
            }
            state.hasPendingLocalChanges = true
        }
    }

    func recordLibraryDeletion(mangaId: MangaIdentifier, at date: Date? = nil) {
        mutateIfActive(at: date) { state, timestamp in
            Self.upsertMaxDate(
                &state.tombstones.libraryManga,
                entry: SyncMangaTombstone(mangaId: mangaId, deletedAt: timestamp),
                matches: { $0.mangaIdentifier == mangaId },
                date: \.deletedAt
            )
            state.hasPendingLocalChanges = true
        }
    }

    func recordHistoryRead(chapterIds: [ChapterIdentifier], at date: Date? = nil) {
        guard !chapterIds.isEmpty, recordingEnabledProvider() else { return }
        let chapterSet = Set(chapterIds)
        lock.lock()
        defer { lock.unlock() }
        guard suspensionDepth == 0 else { return }

        var state = loadStateLocked()
        let timestamp = date ?? nowProvider()
        let wasPending = state.hasPendingLocalChanges
        let previousCount = state.tombstones.history.count
        state.tombstones.history.removeAll {
            chapterSet.contains($0.chapterIdentifier) && $0.deletedAt < timestamp
        }
        let tombstonesChanged = state.tombstones.history.count != previousCount
        state.hasPendingLocalChanges = true
        state.lastMutationAt = max(state.lastMutationAt ?? .distantPast, timestamp)
        mutationEpoch &+= 1

        let shouldCoalesce = wasPending
            && !tombstonesChanged
            && lastDiskSaveAt.map { nowProvider().timeIntervalSince($0) < 2 } == true

        if shouldCoalesce {
            loadedState = state
            dirtyInMemory = true
        } else {
            saveStateLocked(state)
        }
    }

    func recordHistoryDeletion(chapterIds: [ChapterIdentifier], at date: Date? = nil) {
        guard !chapterIds.isEmpty else { return }
        mutateIfActive(at: date) { state, timestamp in
            for chapterId in chapterIds {
                Self.upsertMaxDate(
                    &state.tombstones.history,
                    entry: SyncHistoryTombstone(chapterId: chapterId, deletedAt: timestamp),
                    matches: { $0.chapterIdentifier == chapterId },
                    date: \.deletedAt
                )
            }
            state.hasPendingLocalChanges = true
        }
    }

    func recordMangaHistoryDeletion(mangaId: MangaIdentifier, at date: Date? = nil) {
        mutateIfActive(at: date) { state, timestamp in
            Self.upsertMaxDate(
                &state.tombstones.mangaHistory,
                entry: SyncMangaTombstone(mangaId: mangaId, deletedAt: timestamp),
                matches: { $0.mangaIdentifier == mangaId },
                date: \.deletedAt
            )
            state.hasPendingLocalChanges = true
        }
    }

    func recordAllHistoryCleared(at date: Date? = nil) {
        mutateIfActive(at: date) { state, timestamp in
            state.tombstones.historyClearedAt = SyncMerger.maxOptionalDate(
                state.tombstones.historyClearedAt,
                timestamp
            )
            state.hasPendingLocalChanges = true
        }
    }

    func recordCategoryUpsert(title: String, at date: Date? = nil) {
        guard !title.isEmpty else { return }
        recordCategoryUpserts(titles: [title], at: date)
    }

    func recordCategoryUpserts(titles: [String], at date: Date? = nil) {
        let nonEmpty = titles.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return }
        mutateIfActive(at: date) { state, timestamp in
            let titleSet = Set(nonEmpty)
            state.tombstones.categories.removeAll {
                titleSet.contains($0.title) && $0.deletedAt < timestamp
            }
            for title in nonEmpty {
                Self.upsertMaxDate(
                    &state.tombstones.categoryUpserts,
                    entry: SyncCategoryUpsert(title: title, updatedAt: timestamp),
                    matches: { $0.title == title },
                    date: \.updatedAt
                )
            }
            state.hasPendingLocalChanges = true
        }
    }

    func recordCategoryDeletion(title: String, at date: Date? = nil) {
        guard !title.isEmpty else { return }
        mutateIfActive(at: date) { state, timestamp in
            Self.upsertMaxDate(
                &state.tombstones.categories,
                entry: SyncCategoryTombstone(title: title, deletedAt: timestamp),
                matches: { $0.title == title },
                date: \.deletedAt
            )
            state.hasPendingLocalChanges = true
        }
    }

    func recordMangaCategoriesUpdate(mangaId: MangaIdentifier, at date: Date? = nil) {
        mutateIfActive(at: date) { state, timestamp in
            Self.upsertMaxDate(
                &state.tombstones.mangaCategoryUpdates,
                entry: SyncMangaCategoryUpdate(mangaId: mangaId, updatedAt: timestamp),
                matches: { $0.mangaIdentifier == mangaId },
                date: \.updatedAt
            )
            state.hasPendingLocalChanges = true
        }
    }

    func recordMangaDetailsUpdate(mangaId: MangaIdentifier, at date: Date? = nil) {
        mutateIfActive(at: date, coalesceWithin: 2) { state, timestamp in
            Self.upsertMaxDate(
                &state.tombstones.mangaDetailsUpdates,
                entry: SyncMangaCategoryUpdate(mangaId: mangaId, updatedAt: timestamp),
                matches: { $0.mangaIdentifier == mangaId },
                date: \.updatedAt
            )
            state.hasPendingLocalChanges = true
        }
    }

    func recordMangaFieldUpdates(
        mangaId: MangaIdentifier,
        editedBits: EditedKeys,
        resetBits: EditedKeys,
        at date: Date? = nil
    ) {
        let effectiveReset = resetBits.subtracting(editedBits)
        guard !editedBits.isEmpty || !effectiveReset.isEmpty else { return }
        mutateIfActive(at: date) { state, timestamp in
            for bit in EditedKeys.allMetadataBitFlags {
                let isEdited = editedBits.contains(bit)
                let isReset = effectiveReset.contains(bit)
                guard isEdited || isReset else { continue }
                Self.upsertMaxDate(
                    &state.tombstones.mangaFieldUpdates,
                    entry: SyncMangaFieldUpdate(
                        mangaId: mangaId,
                        fieldBit: bit.rawValue,
                        updatedAt: timestamp,
                        isReset: isReset
                    ),
                    matches: { $0.mangaIdentifier == mangaId && $0.fieldBit == bit.rawValue },
                    date: \.updatedAt
                )
            }
            Self.upsertMaxDate(
                &state.tombstones.mangaDetailsUpdates,
                entry: SyncMangaCategoryUpdate(mangaId: mangaId, updatedAt: timestamp),
                matches: { $0.mangaIdentifier == mangaId },
                date: \.updatedAt
            )
            state.hasPendingLocalChanges = true
        }
    }

    func recordTrackUpsert(trackerId: String, mangaId: MangaIdentifier, at date: Date? = nil) {
        guard !trackerId.isEmpty else { return }
        let key = SyncTrackKey(trackerId: trackerId, mangaId: mangaId)
        mutateIfActive(at: date) { state, timestamp in
            state.tombstones.tracks.removeAll {
                $0.trackKey == key && $0.deletedAt < timestamp
            }
            Self.upsertMaxDate(
                &state.tombstones.trackUpserts,
                entry: SyncTrackUpsert(trackKey: key, updatedAt: timestamp),
                matches: { $0.trackKey == key },
                date: \.updatedAt
            )
            state.hasPendingLocalChanges = true
        }
    }

    func recordTrackDeletion(trackerId: String, mangaId: MangaIdentifier, at date: Date? = nil) {
        guard !trackerId.isEmpty else { return }
        let key = SyncTrackKey(trackerId: trackerId, mangaId: mangaId)
        mutateIfActive(at: date) { state, timestamp in
            Self.upsertMaxDate(
                &state.tombstones.tracks,
                entry: SyncTrackTombstone(trackKey: key, deletedAt: timestamp),
                matches: { $0.trackKey == key },
                date: \.deletedAt
            )
            state.hasPendingLocalChanges = true
        }
    }

    // MARK: - Core Data Bulk Hook Helpers

    func recordTrackDeletions(trackerId: String, context: NSManagedObjectContext) {
        guard !trackerId.isEmpty, isRecordingActive else { return }
        let tracks = CoreDataManager.shared.getTracks(trackerId: trackerId, context: context)
        let keys: [SyncTrackKey] = tracks.compactMap { track in
            guard let sourceId = track.sourceId, let mangaId = track.mangaId else { return nil }
            return SyncTrackKey(trackerId: trackerId, sourceId: sourceId, mangaId: mangaId)
        }
        guard !keys.isEmpty else { return }
        mutateIfActive { state, timestamp in
            for key in keys {
                Self.upsertMaxDate(
                    &state.tombstones.tracks,
                    entry: SyncTrackTombstone(trackKey: key, deletedAt: timestamp),
                    matches: { $0.trackKey == key },
                    date: \.deletedAt
                )
            }
            state.hasPendingLocalChanges = true
        }
    }

    func recordHistoryDeletions(matching request: NSFetchRequest<HistoryObject>, context: NSManagedObjectContext) {
        guard isRecordingActive else { return }
        let fetchRequest = HistoryObject.fetchRequest()
        fetchRequest.predicate = request.predicate
        let items = (try? context.fetch(fetchRequest)) ?? []
        let chapterIds = items.map(\.identifier)
        guard !chapterIds.isEmpty else { return }
        recordHistoryDeletion(chapterIds: chapterIds)
    }

    // MARK: - Private Helpers

    private func mutateIfActive(
        at date: Date? = nil,
        coalesceWithin: TimeInterval? = nil,
        _ mutation: (inout PersistedState, Date) -> Void
    ) {
        guard recordingEnabledProvider() else { return }
        lock.lock()
        defer { lock.unlock() }
        guard suspensionDepth == 0 else { return }
        var state = loadStateLocked()
        let wasPending = state.hasPendingLocalChanges
        let timestamp = date ?? nowProvider()
        mutation(&state, timestamp)
        state.lastMutationAt = max(state.lastMutationAt ?? .distantPast, timestamp)
        mutationEpoch &+= 1

        if
            let coalesceWithin,
            wasPending,
            let lastSave = lastDiskSaveAt,
            nowProvider().timeIntervalSince(lastSave) < coalesceWithin
        {
            loadedState = state
            dirtyInMemory = true
        } else {
            saveStateLocked(state)
        }
    }

    private func loadStateLocked() -> PersistedState {
        if let loadedState {
            return loadedState
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            let empty = PersistedState(tombstones: .empty, hasPendingLocalChanges: false, lastMutationAt: nil)
            loadedState = empty
            return empty
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = (try? decoder.decode(PersistedState.self, from: data))
            ?? PersistedState(tombstones: .empty, hasPendingLocalChanges: false, lastMutationAt: nil)
        loadedState = decoded
        return decoded
    }

    private func saveStateLocked(_ state: PersistedState) {
        var pruned = state
        let cutoff = nowProvider().addingTimeInterval(-SyncMerger.defaultTombstoneTTL)
        pruned.tombstones = SyncMerger.pruneTombstones(state.tombstones, olderThan: cutoff).canonicalized()
        loadedState = pruned
        dirtyInMemory = false
        lastDiskSaveAt = nowProvider()

        fileURL.deletingLastPathComponent().createDirectory()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(pruned) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func upsertMaxDate<T>(
        _ array: inout [T],
        entry: T,
        matches: (T) -> Bool,
        date: (T) -> Date
    ) {
        if let index = array.firstIndex(where: matches) {
            if date(entry) >= date(array[index]) {
                array[index] = entry
            }
        } else {
            array.append(entry)
        }
    }
}
