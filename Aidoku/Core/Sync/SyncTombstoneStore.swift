//
//  SyncTombstoneStore.swift
//  Aidoku
//

import Foundation

final class SyncTombstoneStore: @unchecked Sendable {
    static let shared = SyncTombstoneStore()

    private struct PersistedState: Codable {
        var tombstones: SyncTombstones
        var hasPendingLocalChanges: Bool
    }

    private let fileURL: URL
    private let lock = NSLock()
    private let nowProvider: @Sendable () -> Date
    private var loadedState: PersistedState?
    private var suspensionDepth = 0
    private var mutationEpoch: UInt64 = 0

    init(
        fileURL: URL = FileManager.default.applicationSupportDirectory
            .appendingPathComponent("ForkSync", isDirectory: true)
            .appendingPathComponent("sync_tombstones.json"),
        nowProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.nowProvider = nowProvider
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
            epoch: mutationEpoch
        )
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
                categories: tombstones.categories + state.tombstones.categories,
                tracks: tombstones.tracks + state.tombstones.tracks,
                categoryUpserts: tombstones.categoryUpserts + state.tombstones.categoryUpserts,
                trackUpserts: tombstones.trackUpserts + state.tombstones.trackUpserts,
                mangaCategoryUpdates: tombstones.mangaCategoryUpdates + state.tombstones.mangaCategoryUpdates
            ).canonicalized()
            state.tombstones = merged
        } else {
            state.tombstones = tombstones.canonicalized()
            if clearPendingChanges {
                state.hasPendingLocalChanges = false
            }
        }
        saveStateLocked(state)
    }

    func markPendingLocalChanges() {
        mutateIfActive { state, _ in
            state.hasPendingLocalChanges = true
        }
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        loadedState = PersistedState(tombstones: .empty, hasPendingLocalChanges: false)
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
        guard !chapterIds.isEmpty else { return }
        let chapterSet = Set(chapterIds)
        mutateIfActive(at: date) { state, timestamp in
            state.tombstones.history.removeAll {
                chapterSet.contains($0.chapterIdentifier) && $0.deletedAt < timestamp
            }
            state.hasPendingLocalChanges = true
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

    func recordCategoryUpsert(title: String, at date: Date? = nil) {
        guard !title.isEmpty else { return }
        mutateIfActive(at: date) { state, timestamp in
            state.tombstones.categories.removeAll {
                $0.title == title && $0.deletedAt < timestamp
            }
            Self.upsertMaxDate(
                &state.tombstones.categoryUpserts,
                entry: SyncCategoryUpsert(title: title, updatedAt: timestamp),
                matches: { $0.title == title },
                date: \.updatedAt
            )
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

    // MARK: - Private Helpers

    private func mutateIfActive(at date: Date? = nil, _ mutation: (inout PersistedState, Date) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard suspensionDepth == 0 else { return }
        var state = loadStateLocked()
        let timestamp = date ?? nowProvider()
        mutation(&state, timestamp)
        mutationEpoch &+= 1
        saveStateLocked(state)
    }

    private func loadStateLocked() -> PersistedState {
        if let loadedState {
            return loadedState
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            let empty = PersistedState(tombstones: .empty, hasPendingLocalChanges: false)
            loadedState = empty
            return empty
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = (try? decoder.decode(PersistedState.self, from: data))
            ?? PersistedState(tombstones: .empty, hasPendingLocalChanges: false)
        loadedState = decoded
        return decoded
    }

    private func saveStateLocked(_ state: PersistedState) {
        loadedState = state
        fileURL.deletingLastPathComponent().createDirectory()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(state) else { return }
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
