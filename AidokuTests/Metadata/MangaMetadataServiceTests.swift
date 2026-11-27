//
//  MangaMetadataServiceTests.swift
//  AidokuTests
//

@testable import Aidoku
import AidokuRunner
import Foundation
import Testing

private struct MockTrackerMetadataProvider: TrackerMetadataProvider {
    let trackerId = "mangabaka"
    let trackerName = "MangaBaka"
    let result: TrackerMangaMetadata

    func fetchMetadata(trackId: String) async throws -> TrackerMangaMetadata {
        result
    }
}

@Suite struct MangaMetadataServiceTests {
    @Test func parsesAndFormatsAuthorsAndArtists() {
        #expect(
            MangaMetadataService.parsePersonList(" Kanehito Yamada , Tsukasa Abe, Kanehito Yamada , ")
                == ["Kanehito Yamada", "Tsukasa Abe"]
        )
        #expect(
            MangaMetadataService.formatPersonList(["Kanehito Yamada", " ", "Tsukasa Abe", "Kanehito Yamada"])
                == "Kanehito Yamada, Tsukasa Abe"
        )
    }

    @Test func validatesRemoteCoverURLs() {
        #expect(MangaMetadataService.isValidRemoteCoverURL("https://images.mangabaka.dev/cover.jpg"))
        #expect(MangaMetadataService.isValidRemoteCoverURL("http://192.168.1.5:8080/cover.png"))
        #expect(!MangaMetadataService.isValidRemoteCoverURL(""))
        #expect(!MangaMetadataService.isValidRemoteCoverURL("   "))
        #expect(!MangaMetadataService.isValidRemoteCoverURL("file:///var/mobile/cover.png"))
        #expect(!MangaMetadataService.isValidRemoteCoverURL("javascript:alert(1)"))
        #expect(!MangaMetadataService.isValidRemoteCoverURL("not a url"))
    }

    @MainActor
    @Test func editViewModelTracksModifiedResetAndSelectiveMangaBakaApply() {
        let suiteName = "ForkMetadataVMTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        let priorityStore = TitleLanguagePriorityStore(userDefaults: defaults)
        priorityStore.priorityOrder = ["zh-Hant", "en"]

        let manga = AidokuRunner.Manga(
            sourceKey: "mangadex",
            key: "frieren",
            title: "Sousou no Frieren",
            cover: "https://source.example/old.jpg",
            artists: nil,
            authors: ["Yamada"],
            description: "Original description",
            tags: ["Fantasy"],
            status: .ongoing
        )

        let metadata = TrackerMangaMetadata(
            trackerId: "mangabaka",
            trackerName: "MangaBaka",
            trackId: "1995",
            defaultTitle: "Frieren: Beyond Journey's End",
            titleOptions: [
                .init(languageCode: "en", title: "Frieren: Beyond Journey's End", isPrimary: true, traits: ["official"]),
                .init(languageCode: "zh-Hant", title: "葬送的芙莉蓮", isPrimary: true, traits: [])
            ],
            coverUrl: "https://images.mangabaka.dev/frieren/raw.jpg",
            authors: ["Kanehito Yamada"],
            artists: ["Tsukasa Abe"],
            status: .hiatus,
            description: "Updated synopsis",
            tags: ["Adventure", "Fantasy"]
        )

        let viewModel = EditMetadataViewModel(
            source: nil,
            manga: manga,
            metadataProvider: MockTrackerMetadataProvider(result: metadata),
            languagePriorityStore: priorityStore
        )

        #expect(!viewModel.hasPendingChanges)
        viewModel.applyPulledSelection(
            TrackerMetadataSelection(
                selectedFields: [.title, .artists, .cover],
                selectedTitle: "葬送的芙莉蓮"
            ),
            from: metadata
        )

        #expect(viewModel.title == "葬送的芙莉蓮")
        #expect(viewModel.artistsText == "Tsukasa Abe")
        #expect(viewModel.coverUrl == "https://images.mangabaka.dev/frieren/raw.jpg")
        #expect(viewModel.authorsText == "Yamada")
        #expect(viewModel.isFieldEdited(.title))
        #expect(viewModel.isFieldEdited(.artists))
        #expect(viewModel.isFieldEdited(.cover))
        #expect(!viewModel.isFieldEdited(.authors))
        #expect(viewModel.hasPendingChanges)

        viewModel.addTag()
        viewModel.newTagText = "Slice of Life"
        viewModel.addTag()
        #expect(viewModel.tags == ["Fantasy", "Slice of Life"])
        #expect(viewModel.isFieldEdited(.tags))

        viewModel.resetField(.title)
        #expect(viewModel.title == "Sousou no Frieren")
        #expect(!viewModel.isFieldEdited(.title))

        viewModel.resetAllToSourceDefaults()
        #expect(!viewModel.hasPendingChanges)
        #expect(viewModel.tags == ["Fantasy"])
        #expect(viewModel.coverUrl == "https://source.example/old.jpg")
    }

    @Test func managedCustomCoverCleanupProtectsLocalLibraryFiles() {
        let docs = URL(fileURLWithPath: "/tmp/AidokuDocs", isDirectory: true)

        let managed = MangaMetadataService.managedCustomCoverFileURL(
            for: "aidoku-image:///Covers/abc-123.heic",
            documentsDirectory: docs
        )
        #expect(managed?.path == "/tmp/AidokuDocs/Covers/abc-123.heic")

        let managedWithQuery = MangaMetadataService.managedCustomCoverFileURL(
            for: "aidoku-image:///Covers/abc-123.png?edited=1",
            documentsDirectory: docs
        )
        #expect(managedWithQuery?.path == "/tmp/AidokuDocs/Covers/abc-123.png")

        #expect(
            MangaMetadataService.managedCustomCoverFileURL(
                for: "aidoku-image:///Local/My%20Manga/cover.png",
                documentsDirectory: docs
            ) == nil
        )
        #expect(
            MangaMetadataService.managedCustomCoverFileURL(
                for: "aidoku-image:///Covers/../Local/MyManga/cover.png",
                documentsDirectory: docs
            ) == nil
        )
        #expect(
            MangaMetadataService.managedCustomCoverFileURL(
                for: "aidoku-image:///Covers",
                documentsDirectory: docs
            ) == nil
        )
        #expect(
            MangaMetadataService.managedCustomCoverFileURL(
                for: "https://images.mangabaka.dev/cover.jpg",
                documentsDirectory: docs
            ) == nil
        )
    }

    @Test func saveThrowsWhenResetRequestedForLocalOrMissingSource() async {
        let localManga = AidokuRunner.Manga(
            sourceKey: LocalSourceRunner.sourceKey,
            key: "local-1",
            title: "Local Book",
            status: .ongoing
        )
        let localRequest = MetadataSaveRequest(
            manga: localManga,
            source: nil,
            snapshot: MangaMetadataSnapshot(manga: localManga, editedKeys: [.title]),
            editedFields: [],
            resetFields: [.title],
            pendingCoverImage: nil
        )
        await #expect(throws: MetadataSaveError.sourceUnavailableForReset) {
            try await MangaMetadataService.save(localRequest)
        }

        let remoteManga = AidokuRunner.Manga(
            sourceKey: "mangadex",
            key: "remote-1",
            title: "Remote Book",
            status: .ongoing
        )
        let remoteRequest = MetadataSaveRequest(
            manga: remoteManga,
            source: nil,
            snapshot: MangaMetadataSnapshot(manga: remoteManga, editedKeys: [.title]),
            editedFields: [],
            resetFields: [.title],
            pendingCoverImage: nil
        )
        await #expect(throws: MetadataSaveError.sourceUnavailableForReset) {
            try await MangaMetadataService.save(remoteRequest)
        }
    }

    @MainActor
    @Test func editViewModelDisablesPersistedResetForLocalAndMissingSource() {
        let localManga = AidokuRunner.Manga(
            sourceKey: LocalSourceRunner.sourceKey,
            key: "local-1",
            title: "Persisted Custom Title",
            status: .ongoing
        )
        let localVM = EditMetadataViewModel(
            source: nil,
            manga: localManga,
            initialEditedKeys: [.title]
        )

        #expect(!localVM.canResetToSourceDefaults)
        #expect(localVM.isFieldEdited(.title))
        #expect(!localVM.canResetField(.title))

        localVM.onTitleChanged("Unsaved Edit")
        #expect(localVM.canResetField(.title))

        localVM.resetField(.title)
        #expect(localVM.title == "Persisted Custom Title")
        #expect(localVM.isFieldEdited(.title))
        #expect(localVM.resetFields.isEmpty)
        #expect(!localVM.canResetField(.title))

        let remoteWithoutSource = AidokuRunner.Manga(
            sourceKey: "mangadex",
            key: "remote-1",
            title: "Persisted Custom Title",
            status: .ongoing
        )
        let missingSourceVM = EditMetadataViewModel(
            source: nil,
            manga: remoteWithoutSource,
            initialEditedKeys: [.title]
        )
        #expect(!missingSourceVM.canResetToSourceDefaults)
        #expect(!missingSourceVM.canResetField(.title))
    }

    @Test func pullSheetDiffersAndDefaultsDoNotOverwriteWithEmptyRemoteFields() {
        let draft = MangaMetadataSnapshot(
            cover: "https://source.example/cover.jpg",
            title: "Existing Title",
            authors: ["Existing Author"],
            artists: ["Existing Artist"],
            status: .ongoing,
            description: "Existing Synopsis",
            tags: ["Fantasy"],
            editedKeys: []
        )
        let emptyRemote = TrackerMangaMetadata(
            trackerId: "mangabaka",
            trackerName: "MangaBaka",
            trackId: "1",
            defaultTitle: "Updated Title",
            titleOptions: [],
            coverUrl: "ftp://invalid.example/cover.jpg",
            authors: [],
            artists: [],
            status: .unknown,
            description: nil,
            tags: []
        )

        let selected = MangaBakaMetadataPullSheet.defaultSelectedFields(
            currentDraft: draft,
            metadata: emptyRemote,
            selectedTitle: "Updated Title"
        )
        #expect(selected == [.title])
        #expect(!MangaBakaMetadataPullSheet.fieldDiffers(
            .authors,
            currentDraft: draft,
            metadata: emptyRemote,
            selectedTitle: "Updated Title"
        ))
        #expect(!MangaBakaMetadataPullSheet.fieldDiffers(
            .artists,
            currentDraft: draft,
            metadata: emptyRemote,
            selectedTitle: "Updated Title"
        ))
        #expect(!MangaBakaMetadataPullSheet.fieldDiffers(
            .tags,
            currentDraft: draft,
            metadata: emptyRemote,
            selectedTitle: "Updated Title"
        ))
        #expect(!MangaBakaMetadataPullSheet.fieldDiffers(
            .description,
            currentDraft: draft,
            metadata: emptyRemote,
            selectedTitle: "Updated Title"
        ))
        #expect(!MangaBakaMetadataPullSheet.fieldDiffers(
            .status,
            currentDraft: draft,
            metadata: emptyRemote,
            selectedTitle: "Updated Title"
        ))
        #expect(!MangaBakaMetadataPullSheet.fieldDiffers(
            .cover,
            currentDraft: draft,
            metadata: emptyRemote,
            selectedTitle: "Updated Title"
        ))
    }

    @MainActor
    @Test func editViewModelAppliesEnrichedNativeAuthorsDescriptionAndChosenCover() {
        let manga = AidokuRunner.Manga(
            sourceKey: "mangadex",
            key: "grand-blue",
            title: "Grand Blue",
            cover: "https://source.example/old.jpg",
            artists: ["Kimitake Yoshioka"],
            authors: ["Kenji Inoue"],
            description: "Old English synopsis",
            tags: ["Comedy"],
            status: .ongoing
        )
        let metadata = TrackerMangaMetadata(
            trackerId: "mangabaka",
            trackerName: "MangaBaka",
            trackId: "1264",
            defaultTitle: "Grand Blue Dreaming",
            titleOptions: [],
            coverUrl: "https://images.mangabaka.dev/main.jpg",
            coverOptions: [
                .init(
                    id: "main",
                    rawUrl: "https://images.mangabaka.dev/main.jpg",
                    thumbnailUrl: "https://images.mangabaka.dev/main.jpg",
                    volumeLabel: nil,
                    type: "main",
                    languageCode: "unknown",
                    isMain: true
                ),
                .init(
                    id: "vol2",
                    rawUrl: "https://images.mangabaka.dev/vol2.jpg",
                    thumbnailUrl: "https://cdn.mangabaka.dev/vol2-x250.jpg",
                    volumeLabel: "2",
                    type: "volume",
                    languageCode: "ja",
                    isMain: false
                )
            ],
            totalCoverCount: 2,
            authors: ["Kenji Inoue"],
            nativeAuthors: ["井上堅二"],
            artists: ["Kimitake Yoshioka"],
            nativeArtists: ["吉岡公威"],
            status: .ongoing,
            description: "New English synopsis",
            descriptionOptions: [
                .init(languageCode: "en", text: "New English synopsis", sourceName: "MangaBaka"),
                .init(languageCode: "ja", text: "新しい日本語のあらすじ。", sourceName: "MangaDex")
            ],
            tags: ["Comedy"]
        )

        let viewModel = EditMetadataViewModel(
            source: nil,
            manga: manga,
            metadataProvider: MockTrackerMetadataProvider(result: metadata)
        )
        viewModel.applyPulledSelection(
            TrackerMetadataSelection(
                selectedFields: [.cover, .authors, .artists, .description],
                selectedTitle: "Grand Blue",
                selectedCoverUrl: "https://images.mangabaka.dev/vol2.jpg",
                selectedAuthors: ["井上堅二"],
                selectedArtists: ["吉岡公威"],
                selectedDescription: "新しい日本語のあらすじ。"
            ),
            from: metadata
        )

        #expect(viewModel.coverUrl == "https://images.mangabaka.dev/vol2.jpg")
        #expect(viewModel.authorsText == "井上堅二")
        #expect(viewModel.artistsText == "吉岡公威")
        #expect(viewModel.descriptionText == "新しい日本語のあらすじ。")
        #expect(viewModel.isFieldEdited(.cover))
        #expect(viewModel.isFieldEdited(.authors))
        #expect(viewModel.isFieldEdited(.artists))
        #expect(viewModel.isFieldEdited(.description))
    }

    @Test func pullSheetCandidatesEvaluateCustomCoverNativeStaffAndLocalizedDescription() {
        let draft = MangaMetadataSnapshot(
            cover: "https://images.mangabaka.dev/main.jpg",
            title: "Grand Blue",
            authors: ["Kenji Inoue"],
            artists: ["Kimitake Yoshioka"],
            status: .ongoing,
            description: "Old English synopsis",
            tags: ["Comedy"],
            editedKeys: []
        )
        let candidates = MangaBakaMetadataPullSheet.PullFieldCandidates(
            title: "Grand Blue",
            coverUrl: "https://images.mangabaka.dev/vol5.jpg",
            authors: ["井上堅二"],
            artists: ["吉岡公威"],
            status: .ongoing,
            description: "中文簡介",
            tags: ["Comedy"]
        )
        let selected = MangaBakaMetadataPullSheet.defaultSelectedFields(
            currentDraft: draft,
            candidates: candidates
        )
        #expect(selected == [.cover, .authors, .artists, .description])
    }
}
