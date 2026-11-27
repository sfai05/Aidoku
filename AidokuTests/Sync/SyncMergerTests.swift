//
//  SyncMergerTests.swift
//  AidokuTests
//

@testable import Aidoku
import Foundation
import Testing

@Suite struct SyncMergerTests {
    @Test func historyMergePrefersNewestDateReadAndTieBreakers() {
        let local = SyncEnvelope(
            revision: 1,
            deviceId: "iphone",
            deviceName: "iPhone",
            updatedAt: SyncTestFixtures.date(3_000),
            backup: SyncTestFixtures.makeBackup(
                history: [
                    // Local is newer -> wins over completed=true older remote
                    SyncTestFixtures.makeHistory(
                        chapterId: "c1",
                        dateRead: SyncTestFixtures.date(2_500),
                        progress: 4,
                        total: 0,
                        completed: false
                    ),
                    // Same dateRead -> completed=true wins over false
                    SyncTestFixtures.makeHistory(
                        chapterId: "c2",
                        dateRead: SyncTestFixtures.date(2_000),
                        progress: 10,
                        total: 20,
                        completed: false
                    ),
                    // Same dateRead & completed=false -> higher progress wins
                    SyncTestFixtures.makeHistory(
                        chapterId: "c3",
                        dateRead: SyncTestFixtures.date(2_000),
                        progress: 12,
                        total: 24,
                        completed: false
                    )
                ]
            )
        )

        let remote = SyncEnvelope(
            revision: 2,
            deviceId: "ipad",
            deviceName: "iPad",
            updatedAt: SyncTestFixtures.date(2_900),
            backup: SyncTestFixtures.makeBackup(
                history: [
                    SyncTestFixtures.makeHistory(
                        chapterId: "c1",
                        dateRead: SyncTestFixtures.date(2_100),
                        progress: 20,
                        total: 20,
                        completed: true
                    ),
                    SyncTestFixtures.makeHistory(
                        chapterId: "c2",
                        dateRead: SyncTestFixtures.date(2_000),
                        progress: 20,
                        total: 20,
                        completed: true
                    ),
                    SyncTestFixtures.makeHistory(
                        chapterId: "c3",
                        dateRead: SyncTestFixtures.date(2_000),
                        progress: 8,
                        total: 24,
                        completed: false
                    )
                ]
            )
        )

        let result = SyncMerger.merge(
            local: local,
            remote: remote,
            deviceId: "iphone",
            deviceName: "iPhone",
            now: SyncTestFixtures.date(4_000)
        )

        let byChapter = Dictionary(
            (result.mergedEnvelope.backup.history ?? []).map { ($0.chapterId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        #expect(byChapter["c1"]?.dateRead == SyncTestFixtures.date(2_500))
        #expect(byChapter["c1"]?.completed == false)
        // Non-zero total from losing entry preserved when winner had 0
        #expect(byChapter["c1"]?.total == 20)

        #expect(byChapter["c2"]?.completed == true)
        #expect(byChapter["c3"]?.progress == 12)
        #expect(result.localNeedsApply)
        #expect(result.remoteNeedsUpload)
    }

    @Test func historyTombstonesSuppressOlderReadsAndAllowReReads() {
        let deletedMangaId = MangaIdentifier(sourceKey: "mangadex", mangaKey: "m-clear")
        let local = SyncEnvelope(
            revision: 1,
            deviceId: "iphone",
            deviceName: "iPhone",
            updatedAt: SyncTestFixtures.date(5_000),
            tombstones: SyncTombstones(
                history: [
                    SyncHistoryTombstone(
                        sourceId: "mangadex",
                        mangaId: "m1",
                        chapterId: "c1",
                        deletedAt: SyncTestFixtures.date(3_000)
                    ),
                    SyncHistoryTombstone(
                        sourceId: "mangadex",
                        mangaId: "m1",
                        chapterId: "c2",
                        deletedAt: SyncTestFixtures.date(3_000)
                    )
                ],
                mangaHistory: [
                    SyncMangaTombstone(mangaId: deletedMangaId, deletedAt: SyncTestFixtures.date(3_000))
                ]
            ),
            backup: SyncTestFixtures.makeBackup(
                history: [
                    SyncTestFixtures.makeHistory(
                        mangaId: "m1",
                        chapterId: "c2",
                        dateRead: SyncTestFixtures.date(3_500),
                        progress: 10,
                        total: 10,
                        completed: true
                    )
                ]
            )
        )

        let remote = SyncEnvelope(
            revision: 2,
            deviceId: "ipad",
            deviceName: "iPad",
            updatedAt: SyncTestFixtures.date(4_500),
            backup: SyncTestFixtures.makeBackup(
                history: [
                    SyncTestFixtures.makeHistory(
                        mangaId: "m1",
                        chapterId: "c1",
                        dateRead: SyncTestFixtures.date(2_500),
                        completed: true
                    ),
                    SyncTestFixtures.makeHistory(
                        mangaId: "m1",
                        chapterId: "c2",
                        dateRead: SyncTestFixtures.date(2_000),
                        progress: 3,
                        completed: false
                    ),
                    SyncTestFixtures.makeHistory(
                        mangaId: "m-clear",
                        chapterId: "c-old",
                        dateRead: SyncTestFixtures.date(2_900),
                        completed: true
                    ),
                    SyncTestFixtures.makeHistory(
                        mangaId: "m-clear",
                        chapterId: "c-new",
                        dateRead: SyncTestFixtures.date(3_200),
                        completed: true
                    )
                ],
                readingSessions: [
                    SyncTestFixtures.makeSession(
                        mangaId: "m1",
                        chapterId: "c1",
                        pagesRead: 10,
                        startDate: SyncTestFixtures.date(2_400),
                        endDate: SyncTestFixtures.date(2_500)
                    ),
                    SyncTestFixtures.makeSession(
                        mangaId: "m1",
                        chapterId: "c2",
                        pagesRead: 5,
                        startDate: SyncTestFixtures.date(3_400),
                        endDate: SyncTestFixtures.date(3_500)
                    )
                ]
            )
        )

        let result = SyncMerger.merge(
            local: local,
            remote: remote,
            deviceId: "iphone",
            deviceName: "iPhone",
            now: SyncTestFixtures.date(5_500)
        )

        let chapters = Set((result.mergedEnvelope.backup.history ?? []).map(\.chapterId))
        #expect(!chapters.contains("c1"))
        #expect(chapters.contains("c2"))
        #expect(!chapters.contains("c-old"))
        #expect(chapters.contains("c-new"))

        // c2 chapter tombstone pruned because re-read at 3500 > deletedAt 3000; c1 remains.
        let tombstoneChapters = Set(result.mergedEnvelope.tombstones.history.map(\.chapterId))
        #expect(tombstoneChapters.contains("c1"))
        #expect(!tombstoneChapters.contains("c2"))

        // Suppressed reading session for c1 dropped; c2 reading session retained.
        let sessionChapters = Set((result.mergedEnvelope.backup.readingSessions ?? []).map(\.chapterId))
        #expect(!sessionChapters.contains("c1"))
        #expect(sessionChapters.contains("c2"))
    }

    @Test func libraryUnionDeletionAndReAdditionReconciliation() {
        let m1 = MangaIdentifier(sourceKey: "mangadex", mangaKey: "m1")
        let mDeleted = MangaIdentifier(sourceKey: "mangadex", mangaKey: "m-deleted")
        let mReAdded = MangaIdentifier(sourceKey: "mangadex", mangaKey: "m-readded")
        let mRemoteOnly = MangaIdentifier(sourceKey: "mangadex", mangaKey: "m-remote")

        let local = SyncEnvelope(
            revision: 3,
            deviceId: "iphone",
            deviceName: "iPhone",
            updatedAt: SyncTestFixtures.date(5_000),
            tombstones: SyncTombstones(
                libraryManga: [
                    SyncMangaTombstone(mangaId: mDeleted, deletedAt: SyncTestFixtures.date(4_000)),
                    SyncMangaTombstone(mangaId: mReAdded, deletedAt: SyncTestFixtures.date(3_000))
                ]
            ),
            backup: SyncTestFixtures.makeBackup(
                library: [
                    SyncTestFixtures.makeLibraryManga(
                        mangaId: m1.mangaKey,
                        dateAdded: SyncTestFixtures.date(1_000),
                        lastOpened: SyncTestFixtures.date(4_500),
                        lastUpdated: SyncTestFixtures.date(2_000),
                        lastRead: SyncTestFixtures.date(4_400)
                    ),
                    SyncTestFixtures.makeLibraryManga(
                        mangaId: mReAdded.mangaKey,
                        dateAdded: SyncTestFixtures.date(3_800),
                        lastOpened: SyncTestFixtures.date(3_800),
                        lastUpdated: SyncTestFixtures.date(3_800)
                    )
                ],
                manga: [
                    SyncTestFixtures.makeManga(id: m1.mangaKey),
                    SyncTestFixtures.makeManga(id: mReAdded.mangaKey, title: "Re-Added Series")
                ]
            )
        )

        let remote = SyncEnvelope(
            revision: 4,
            deviceId: "ipad",
            deviceName: "iPad",
            updatedAt: SyncTestFixtures.date(4_800),
            backup: SyncTestFixtures.makeBackup(
                library: [
                    SyncTestFixtures.makeLibraryManga(
                        mangaId: m1.mangaKey,
                        dateAdded: SyncTestFixtures.date(1_200),
                        lastOpened: SyncTestFixtures.date(3_000),
                        lastUpdated: SyncTestFixtures.date(3_500),
                        lastRead: SyncTestFixtures.date(2_900)
                    ),
                    SyncTestFixtures.makeLibraryManga(
                        mangaId: mDeleted.mangaKey,
                        dateAdded: SyncTestFixtures.date(2_000)
                    ),
                    SyncTestFixtures.makeLibraryManga(
                        mangaId: mRemoteOnly.mangaKey,
                        dateAdded: SyncTestFixtures.date(2_500)
                    )
                ],
                history: [
                    SyncTestFixtures.makeHistory(mangaId: mDeleted.mangaKey, chapterId: "c1", completed: true)
                ],
                manga: [
                    SyncTestFixtures.makeManga(id: m1.mangaKey),
                    SyncTestFixtures.makeManga(id: mDeleted.mangaKey),
                    SyncTestFixtures.makeManga(id: mRemoteOnly.mangaKey)
                ],
                chapters: [
                    SyncTestFixtures.makeChapter(mangaId: mDeleted.mangaKey, id: "c1")
                ],
                trackItems: [
                    SyncTestFixtures.makeTrackItem(mangaId: mDeleted.mangaKey)
                ]
            )
        )

        let result = SyncMerger.merge(
            local: local,
            remote: remote,
            deviceId: "iphone",
            deviceName: "iPhone",
            now: SyncTestFixtures.date(6_000)
        )

        let mergedLibraryIds = Set((result.mergedEnvelope.backup.library ?? []).map(\.mangaId))
        #expect(mergedLibraryIds == ["m1", "m-readded", "m-remote"])

        let m1Merged = result.mergedEnvelope.backup.library?.first { $0.mangaId == "m1" }
        #expect(m1Merged?.dateAdded == SyncTestFixtures.date(1_000))
        #expect(m1Merged?.lastOpened == SyncTestFixtures.date(4_500))
        #expect(m1Merged?.lastUpdated == SyncTestFixtures.date(3_500))
        #expect(m1Merged?.lastRead == SyncTestFixtures.date(4_400))

        // Deleted library manga removes manga/chapters/tracks, while keeping independent history.
        #expect(!(result.mergedEnvelope.backup.manga ?? []).contains { $0.id == mDeleted.mangaKey })
        #expect(!(result.mergedEnvelope.backup.chapters ?? []).contains { $0.mangaId == mDeleted.mangaKey })
        #expect(!(result.mergedEnvelope.backup.trackItems ?? []).contains { $0.mangaId == mDeleted.mangaKey })
        #expect((result.mergedEnvelope.backup.history ?? []).contains { $0.mangaId == mDeleted.mangaKey })

        // Re-added manga clears its old library tombstone.
        let activeDeleted = Set(result.mergedEnvelope.tombstones.libraryManga.map(\.mangaId))
        #expect(activeDeleted == [mDeleted.mangaKey])
    }
}

@Suite struct SyncMergerCategoryAndMetadataTests {
    @Test func categoryDeletionAndMangaCategoryAssignmentRespectsTimestamps() {
        let m1 = MangaIdentifier(sourceKey: "mangadex", mangaKey: "m1")

        let local = SyncEnvelope(
            revision: 1,
            deviceId: "iphone",
            deviceName: "iPhone",
            updatedAt: SyncTestFixtures.date(5_000),
            tombstones: SyncTombstones(
                categories: [
                    SyncCategoryTombstone(title: "Dropped", deletedAt: SyncTestFixtures.date(4_000)),
                    SyncCategoryTombstone(title: "Action", deletedAt: SyncTestFixtures.date(2_000))
                ],
                categoryUpserts: [
                    SyncCategoryUpsert(title: "Action", updatedAt: SyncTestFixtures.date(4_500)),
                    SyncCategoryUpsert(title: "Reading", updatedAt: SyncTestFixtures.date(1_000))
                ],
                mangaCategoryUpdates: [
                    SyncMangaCategoryUpdate(mangaId: m1, updatedAt: SyncTestFixtures.date(4_600))
                ]
            ),
            backup: SyncTestFixtures.makeBackup(
                library: [
                    SyncTestFixtures.makeLibraryManga(mangaId: "m1", categories: ["Action", "Reading"])
                ],
                manga: [SyncTestFixtures.makeManga(id: "m1")],
                categories: [
                    SyncTestFixtures.makeCategory(title: "Action", sort: 0),
                    SyncTestFixtures.makeCategory(title: "Reading", sort: 1)
                ]
            )
        )

        let remote = SyncEnvelope(
            revision: 2,
            deviceId: "ipad",
            deviceName: "iPad",
            updatedAt: SyncTestFixtures.date(4_000),
            tombstones: SyncTombstones(
                mangaCategoryUpdates: [
                    SyncMangaCategoryUpdate(mangaId: m1, updatedAt: SyncTestFixtures.date(3_000))
                ]
            ),
            backup: SyncTestFixtures.makeBackup(
                library: [
                    SyncTestFixtures.makeLibraryManga(mangaId: "m1", categories: ["Dropped", "Completed"])
                ],
                manga: [SyncTestFixtures.makeManga(id: "m1")],
                categories: [
                    SyncTestFixtures.makeCategory(title: "Dropped", sort: 0),
                    SyncTestFixtures.makeCategory(title: "Completed", sort: 1)
                ]
            )
        )

        let result = SyncMerger.merge(
            local: local,
            remote: remote,
            deviceId: "iphone",
            deviceName: "iPhone",
            now: SyncTestFixtures.date(6_000)
        )

        let titles = Set((result.mergedEnvelope.backup.categories ?? []).compactMap(\.title))
        #expect(titles == ["Action", "Reading", "Completed"])
        #expect(!titles.contains("Dropped"))

        let m1Categories = result.mergedEnvelope.backup.library?.first?.categories ?? []
        #expect(m1Categories == ["Action", "Reading"])

        let categoryTombstones = Set(result.mergedEnvelope.tombstones.categories.map(\.title))
        #expect(categoryTombstones == ["Dropped"])
    }

    @Test func tracksReconcileTombstonesAndEditedKeysArePreserved() {
        let editedFlags = EditedKeys.title.union(.cover).union(.tags).rawValue

        let local = SyncEnvelope(
            revision: 1,
            deviceId: "iphone",
            deviceName: "iPhone",
            updatedAt: SyncTestFixtures.date(2_000),
            tombstones: SyncTombstones(
                tracks: [
                    SyncTrackTombstone(trackerId: "mal", sourceId: "mangadex", mangaId: "m1", deletedAt: SyncTestFixtures.date(1_800))
                ]
            ),
            backup: SyncTestFixtures.makeBackup(
                library: [
                    SyncTestFixtures.makeLibraryManga(mangaId: "m1", lastUpdated: SyncTestFixtures.date(1_500))
                ],
                manga: [
                    SyncTestFixtures.makeManga(
                        id: "m1",
                        title: "Custom Edited Title",
                        tags: ["CustomTag"],
                        cover: "aidoku-image:///Covers/custom.heic",
                        editedKeys: Int(editedFlags)
                    )
                ],
                trackItems: [
                    SyncTestFixtures.makeTrackItem(id: "a1", trackerId: "anilist", mangaId: "m1")
                ]
            )
        )

        let remote = SyncEnvelope(
            revision: 2,
            deviceId: "ipad",
            deviceName: "iPad",
            updatedAt: SyncTestFixtures.date(3_000),
            backup: SyncTestFixtures.makeBackup(
                library: [
                    SyncTestFixtures.makeLibraryManga(mangaId: "m1", lastUpdated: SyncTestFixtures.date(2_900))
                ],
                manga: [
                    SyncTestFixtures.makeManga(
                        id: "m1",
                        title: "Upstream Source Title",
                        author: "Updated Author",
                        tags: ["SourceTag"],
                        cover: "https://example.com/upstream.jpg",
                        editedKeys: 0
                    )
                ],
                trackItems: [
                    SyncTestFixtures.makeTrackItem(id: "m1-mal", trackerId: "mal", mangaId: "m1"),
                    SyncTestFixtures.makeTrackItem(id: "k1", trackerId: "komga", mangaId: "m1")
                ]
            )
        )

        let result = SyncMerger.merge(
            local: local,
            remote: remote,
            deviceId: "iphone",
            deviceName: "iPhone",
            now: SyncTestFixtures.date(4_000)
        )

        let mergedManga = result.mergedEnvelope.backup.manga?.first
        #expect(mergedManga?.title == "Custom Edited Title")
        #expect(mergedManga?.cover == "aidoku-image:///Covers/custom.heic")
        #expect(mergedManga?.tags == ["CustomTag"])
        // Non-edited author adopts newer remote value.
        #expect(mergedManga?.author == "Updated Author")
        #expect(mergedManga?.editedKeys == Int(editedFlags))

        let trackerIds = Set((result.mergedEnvelope.backup.trackItems ?? []).map(\.trackerId))
        #expect(trackerIds == ["anilist", "komga"])
        #expect(!trackerIds.contains("mal"))
    }

    @Test func mergeIsIdempotentWhenStatesAlreadyMatch() {
        let localBackup = SyncTestFixtures.makeBackup(
            library: [SyncTestFixtures.makeLibraryManga(mangaId: "m1", categories: ["Favs"])],
            history: [SyncTestFixtures.makeHistory(mangaId: "m1", chapterId: "c1", completed: true)],
            manga: [SyncTestFixtures.makeManga(id: "m1")],
            chapters: [SyncTestFixtures.makeChapter(mangaId: "m1", id: "c1")],
            vocabulary: [SyncTestFixtures.makeVocab(word: "本")],
            updates: [SyncTestFixtures.makeUpdate(mangaId: "m1", chapterId: "c1", viewed: false)],
            categories: [SyncTestFixtures.makeCategory(title: "Favs", sort: 0)],
            date: SyncTestFixtures.date(1_000),
            version: "0.7.1"
        )
        let remoteBackup = SyncTestFixtures.makeBackup(
            library: [SyncTestFixtures.makeLibraryManga(mangaId: "m1", categories: ["Favs"])],
            history: [SyncTestFixtures.makeHistory(mangaId: "m1", chapterId: "c1", completed: true)],
            manga: [SyncTestFixtures.makeManga(id: "m1")],
            chapters: [SyncTestFixtures.makeChapter(mangaId: "m1", id: "c1")],
            vocabulary: [SyncTestFixtures.makeVocab(word: "本")],
            updates: [SyncTestFixtures.makeUpdate(mangaId: "m1", chapterId: "c1", viewed: false)],
            categories: [SyncTestFixtures.makeCategory(title: "Favs", sort: 0)],
            date: SyncTestFixtures.date(9_999),
            version: "0.7.2"
        )

        let local = SyncEnvelope(
            revision: 5,
            deviceId: "iphone",
            deviceName: "iPhone",
            updatedAt: SyncTestFixtures.date(5_000),
            backup: localBackup
        )
        let remote = SyncEnvelope(
            revision: 5,
            deviceId: "ipad",
            deviceName: "iPad",
            updatedAt: SyncTestFixtures.date(4_000),
            backup: remoteBackup
        )

        let result = SyncMerger.merge(
            local: local,
            remote: remote,
            deviceId: "iphone",
            deviceName: "iPhone",
            now: SyncTestFixtures.date(6_000)
        )

        #expect(!result.localNeedsApply)
        #expect(!result.remoteNeedsUpload)
        #expect(result.stats.libraryCount == 1)
        #expect(result.stats.historyCount == 1)
        #expect(result.stats.categoryCount == 1)
    }

    @Test func expiredTombstonesArePrunedAfterTTL() {
        let now = SyncTestFixtures.date(10_000_000)
        let oldDate = now.addingTimeInterval(-(SyncMerger.defaultTombstoneTTL + 60))
        let freshDate = now.addingTimeInterval(-3_600)

        let local = SyncEnvelope(
            revision: 1,
            deviceId: "d1",
            deviceName: "Device",
            updatedAt: now,
            tombstones: SyncTombstones(
                libraryManga: [
                    SyncMangaTombstone(sourceId: "s1", mangaId: "old", deletedAt: oldDate),
                    SyncMangaTombstone(sourceId: "s1", mangaId: "fresh", deletedAt: freshDate)
                ]
            ),
            backup: SyncTestFixtures.makeBackup()
        )
        let remote = SyncEnvelope(
            revision: 1,
            deviceId: "d2",
            deviceName: "Device 2",
            updatedAt: now,
            tombstones: .empty,
            backup: SyncTestFixtures.makeBackup()
        )

        let result = SyncMerger.merge(
            local: local,
            remote: remote,
            deviceId: "d1",
            deviceName: "Device",
            now: now
        )

        let remainingIds = result.mergedEnvelope.tombstones.libraryManga.map(\.mangaId)
        #expect(remainingIds == ["fresh"])
    }
}

@Suite struct SyncMergerTieBreakAndClearTests {
    @Test func staleDeviceDoesNotOverwriteRemoteChapterFlagsOnEqualLastUpdated() {
        let m1 = MangaIdentifier(sourceKey: "mangadex", mangaKey: "m1")
        // Remote device A (rev 3) edited m1.chapterFlags = 7, langFilter, scanlatorFilter with tied lastUpdated.
        let remoteA = SyncEnvelope(
            revision: 3,
            deviceId: "ipad-a",
            deviceName: "iPad",
            updatedAt: SyncTestFixtures.date(3_000),
            backup: SyncTestFixtures.makeBackup(
                library: [
                    SyncTestFixtures.makeLibraryManga(
                        mangaId: m1.mangaKey,
                        lastUpdated: SyncTestFixtures.date(1_000)
                    )
                ],
                manga: [
                    SyncTestFixtures.makeManga(
                        id: m1.mangaKey,
                        chapterFlags: 7,
                        langFilter: "ja",
                        scanlatorFilter: ["GroupA"]
                    )
                ]
            )
        )

        // Stale device B (rev 2) later added unrelated m2 (giving B a newer envelope updatedAt = 5_000),
        // while its copy of m1 still has stale chapterFlags = 0 and equal lastUpdated = 1_000.
        let staleLocalB = SyncEnvelope(
            revision: 2,
            deviceId: "iphone-b",
            deviceName: "iPhone",
            updatedAt: SyncTestFixtures.date(5_000),
            backup: SyncTestFixtures.makeBackup(
                library: [
                    SyncTestFixtures.makeLibraryManga(
                        mangaId: m1.mangaKey,
                        lastUpdated: SyncTestFixtures.date(1_000)
                    ),
                    SyncTestFixtures.makeLibraryManga(
                        mangaId: "m2",
                        lastUpdated: SyncTestFixtures.date(5_000)
                    )
                ],
                manga: [
                    SyncTestFixtures.makeManga(
                        id: m1.mangaKey,
                        chapterFlags: 0,
                        langFilter: nil,
                        scanlatorFilter: nil
                    ),
                    SyncTestFixtures.makeManga(id: "m2", title: "Local Addition")
                ]
            )
        )

        let mergeFromStale = SyncMerger.merge(
            local: staleLocalB,
            remote: remoteA,
            deviceId: "iphone-b",
            deviceName: "iPhone",
            now: SyncTestFixtures.date(6_000)
        )
        let mergedM1 = mergeFromStale.mergedEnvelope.backup.manga?.first { $0.id == "m1" }
        #expect(mergedM1?.chapterFlags == 7)
        #expect(mergedM1?.langFilter == "ja")
        #expect(mergedM1?.scanlatorFilter == ["GroupA"])
        #expect(mergeFromStale.mergedEnvelope.backup.manga?.contains { $0.id == "m2" } == true)

        // When B explicitly edited m1 details later (recorded in mangaDetailsUpdates), B's update wins.
        var editedLocalB = staleLocalB
        editedLocalB = SyncEnvelope(
            revision: 2,
            deviceId: "iphone-b",
            deviceName: "iPhone",
            updatedAt: SyncTestFixtures.date(5_000),
            tombstones: SyncTombstones(
                mangaDetailsUpdates: [
                    SyncMangaCategoryUpdate(mangaId: m1, updatedAt: SyncTestFixtures.date(4_000))
                ]
            ),
            backup: SyncTestFixtures.makeBackup(
                library: staleLocalB.backup.library ?? [],
                manga: [
                    SyncTestFixtures.makeManga(id: m1.mangaKey, chapterFlags: 3, langFilter: "en"),
                    SyncTestFixtures.makeManga(id: "m2", title: "Local Addition")
                ]
            )
        )

        let mergeFromExplicitEdit = SyncMerger.merge(
            local: editedLocalB,
            remote: remoteA,
            deviceId: "iphone-b",
            deviceName: "iPhone",
            now: SyncTestFixtures.date(6_000)
        )
        let editedM1 = mergeFromExplicitEdit.mergedEnvelope.backup.manga?.first { $0.id == "m1" }
        #expect(editedM1?.chapterFlags == 3)
        #expect(editedM1?.langFilter == "en")
    }

    @Test func settingsAndSourcesMergeRespectsStaleDeviceAndBreaksTiesSymmetrically() {
        let localStale = SyncEnvelope(
            revision: 2,
            deviceId: "iphone-b",
            deviceName: "iPhone",
            updatedAt: SyncTestFixtures.date(5_000),
            backup: SyncTestFixtures.makeBackup(
                sources: [SyncTestFixtures.makeSource(id: "komga-1", apiVersion: "1", config: Data([0x01]))],
                settings: ["Reader.readingMode": .string("ltr")]
            )
        )
        let remoteNewer = SyncEnvelope(
            revision: 3,
            deviceId: "ipad-a",
            deviceName: "iPad",
            updatedAt: SyncTestFixtures.date(3_000),
            backup: SyncTestFixtures.makeBackup(
                sources: [SyncTestFixtures.makeSource(id: "komga-1", apiVersion: "2", config: Data([0x02]))],
                settings: ["Reader.readingMode": .string("webtoon")]
            )
        )

        // When local settings were not modified, remote wins even if local has a newer envelope timestamp.
        let untouchedMerge = SyncMerger.merge(
            local: localStale,
            remote: remoteNewer,
            deviceId: "iphone-b",
            deviceName: "iPhone",
            now: SyncTestFixtures.date(6_000),
            includeSettings: true,
            localSettingsModified: false
        )
        #expect(untouchedMerge.mergedEnvelope.backup.settings?["Reader.readingMode"] == .string("webtoon"))
        #expect(untouchedMerge.mergedEnvelope.backup.sources?.first?.apiVersion == "2")

        // When local settings were actively edited later, local wins on settings.
        let editedMerge = SyncMerger.merge(
            local: localStale,
            remote: remoteNewer,
            deviceId: "iphone-b",
            deviceName: "iPhone",
            now: SyncTestFixtures.date(6_000),
            includeSettings: true,
            localSettingsModified: true
        )
        #expect(editedMerge.mergedEnvelope.backup.settings?["Reader.readingMode"] == .string("ltr"))

        // Merge symmetry with nil localSettingsModified: merge(A, B) matches merge(B, A) payload.
        let forward = SyncMerger.merge(
            local: localStale,
            remote: remoteNewer,
            deviceId: "d1",
            deviceName: "D1",
            now: SyncTestFixtures.date(6_000),
            includeSettings: true
        )
        let reverse = SyncMerger.merge(
            local: remoteNewer,
            remote: localStale,
            deviceId: "d1",
            deviceName: "D1",
            now: SyncTestFixtures.date(6_000),
            includeSettings: true
        )
        #expect(forward.mergedEnvelope.backup.settings == reverse.mergedEnvelope.backup.settings)
        #expect(forward.mergedEnvelope.backup.sources == reverse.mergedEnvelope.backup.sources)
    }

    @Test func bulkHistoryClearTombstoneSuppressesOlderHistoryAndSessions() {
        let local = SyncEnvelope(
            revision: 2,
            deviceId: "iphone",
            deviceName: "iPhone",
            updatedAt: SyncTestFixtures.date(4_000),
            tombstones: SyncTombstones(historyClearedAt: SyncTestFixtures.date(3_000)),
            backup: SyncTestFixtures.makeBackup(
                history: [
                    SyncTestFixtures.makeHistory(
                        mangaId: "m1",
                        chapterId: "c-after",
                        dateRead: SyncTestFixtures.date(3_500),
                        completed: true
                    )
                ],
                readingSessions: [
                    SyncTestFixtures.makeSession(
                        mangaId: "m1",
                        chapterId: "c-after",
                        pagesRead: 8,
                        startDate: SyncTestFixtures.date(3_400),
                        endDate: SyncTestFixtures.date(3_500)
                    )
                ]
            )
        )

        let remote = SyncEnvelope(
            revision: 3,
            deviceId: "ipad",
            deviceName: "iPad",
            updatedAt: SyncTestFixtures.date(2_900),
            backup: SyncTestFixtures.makeBackup(
                history: [
                    SyncTestFixtures.makeHistory(
                        mangaId: "m1",
                        chapterId: "c-before",
                        dateRead: SyncTestFixtures.date(2_500),
                        completed: true
                    ),
                    SyncTestFixtures.makeHistory(
                        mangaId: "m2",
                        chapterId: "c-boundary",
                        dateRead: SyncTestFixtures.date(3_000),
                        completed: true
                    )
                ],
                readingSessions: [
                    SyncTestFixtures.makeSession(
                        mangaId: "m1",
                        chapterId: "c-before",
                        pagesRead: 12,
                        startDate: SyncTestFixtures.date(2_400),
                        endDate: SyncTestFixtures.date(2_500)
                    ),
                    SyncTestFixtures.makeSession(
                        mangaId: "m2",
                        chapterId: "c-boundary",
                        pagesRead: 10,
                        startDate: SyncTestFixtures.date(2_900),
                        endDate: SyncTestFixtures.date(3_000)
                    )
                ]
            )
        )

        let result = SyncMerger.merge(
            local: local,
            remote: remote,
            deviceId: "iphone",
            deviceName: "iPhone",
            now: SyncTestFixtures.date(5_000)
        )

        let mergedHistoryIds = (result.mergedEnvelope.backup.history ?? []).map(\.chapterId)
        #expect(mergedHistoryIds == ["c-after"])
        let mergedSessionIds = (result.mergedEnvelope.backup.readingSessions ?? []).map(\.chapterId)
        #expect(mergedSessionIds == ["c-after"])
        #expect(result.mergedEnvelope.tombstones.historyClearedAt == SyncTestFixtures.date(3_000))
    }
}
