//
//  MangaBakaMetadataTests.swift
//  AidokuTests
//

@testable import Aidoku
import AidokuRunner
import Foundation
import Testing

@Suite struct MangaBakaMetadataTests {
    @Test func decodesFullMangaBakaSeriesAndMapsMetadata() throws {
        let json = """
        {
          "status": 200,
          "data": {
            "id": 1995,
            "title": "Frieren: Beyond Journey’s End",
            "native_title": "葬送のフリーレン",
            "romanized_title": "Sousou no Frieren",
            "original_language": "ja",
            "cover": {
              "raw": {
                "url": "https://images.mangabaka.dev/frieren/raw.jpg"
              }
            },
            "authors": ["Kanehito Yamada", " Kanehito Yamada "],
            "artists": ["Tsukasa Abe"],
            "description": "  Elven mage Frieren embarks on a new journey.  ",
            "status": "hiatus",
            "type": "manga",
            "genres": ["adventure", "slice_of_life", "sci_fi", "award_winning"],
            "titles": [
              { "language": "en", "title": "Frieren: Beyond Journey's End", "is_primary": true, "traits": ["official"] },
              { "language": "zh-Hant", "title": "葬送的芙莉蓮", "is_primary": true, "traits": [] },
              { "language": "zh", "title": "葬送的芙莉莲", "is_primary": false, "traits": [] },
              { "language": "ja", "title": "葬送のフリーレン", "is_primary": true, "traits": ["native"] },
              { "language": "ja-Latn", "title": "Sousou no Frieren", "is_primary": true, "traits": ["native"] }
            ]
          }
        }
        """

        let response = try JSONDecoder().decode(
            MangaBakaResponse<MangaBakaSeries>.self,
            from: Data(json.utf8)
        )
        let series = try #require(response.data)
        let mapped = MangaBakaMetadataProvider.map(series: series, trackId: "1995")

        #expect(mapped.trackerId == "mangabaka")
        #expect(mapped.trackId == "1995")
        #expect(mapped.coverUrl == "https://images.mangabaka.dev/frieren/raw.jpg")
        #expect(mapped.authors == ["Kanehito Yamada"])
        #expect(mapped.artists == ["Tsukasa Abe"])
        #expect(mapped.status == .hiatus)
        #expect(mapped.description == "Elven mage Frieren embarks on a new journey.")
        #expect(mapped.tags == ["Adventure", "Slice of Life", "Sci-Fi", "Award Winning"])

        // Ensures native/romanized entries are deduplicated against existing titles array.
        let jaMatches = mapped.titleOptions.filter { $0.languageCode == "ja" && $0.title == "葬送のフリーレン" }
        #expect(jaMatches.count == 1)
        #expect(mapped.titleOptions.contains { $0.languageCode == "zh-Hant" && $0.title == "葬送的芙莉蓮" })
        #expect(mapped.titleOptions.contains { $0.languageCode == "zh" && $0.title == "葬送的芙莉莲" })
    }

    @Test func decodesLegacyMinimalMangaBakaPayloadWithoutExtendedFields() throws {
        let json = """
        {
          "status": 200,
          "data": {
            "id": 42,
            "title": "DICE",
            "cover": { "raw": { "url": null } },
            "description": null,
            "status": "releasing",
            "type": "manhwa",
            "total_chapters": null,
            "final_volume": null
          }
        }
        """

        let response = try JSONDecoder().decode(
            MangaBakaResponse<MangaBakaSeries>.self,
            from: Data(json.utf8)
        )
        let series = try #require(response.data)
        let mapped = MangaBakaMetadataProvider.map(series: series, trackId: "42")

        #expect(mapped.defaultTitle == "DICE")
        #expect(mapped.status == .ongoing)
        #expect(mapped.coverUrl == nil)
        #expect(mapped.authors.isEmpty)
        #expect(mapped.artists.isEmpty)
        #expect(mapped.tags.isEmpty)
        #expect(mapped.titleOptions.first?.title == "DICE")
    }

    @Test func mapsAllMangaBakaStatusesAndGenreFormatting() {
        #expect(MangaBakaStatus.releasing.toRunnerStatus() == .ongoing)
        #expect(MangaBakaStatus.completed.toRunnerStatus() == .completed)
        #expect(MangaBakaStatus.hiatus.toRunnerStatus() == .hiatus)
        #expect(MangaBakaStatus.cancelled.toRunnerStatus() == .cancelled)
        #expect(MangaBakaStatus.unknown.toRunnerStatus() == .unknown)
        #expect(MangaBakaStatus.upcoming.toRunnerStatus() == .unknown)

        #expect(MangaBakaMetadataProvider.formatGenre("boys_love") == "Boys' Love")
        #expect(MangaBakaMetadataProvider.formatGenre("girls_love") == "Girls' Love")
        #expect(MangaBakaMetadataProvider.formatGenre("magical_girls") == "Magical Girls")
        #expect(MangaBakaMetadataProvider.formatGenre("slice_of_life") == "Slice of Life")
    }

    @Test func mapsMangaBakaContentRatingsAndLenientlyDecodesMissingOrMalformedValues() throws {
        #expect(MangaBakaMetadataProvider.mapContentRating("safe") == .safe)
        #expect(MangaBakaMetadataProvider.mapContentRating(" suggestive ") == .suggestive)
        #expect(MangaBakaMetadataProvider.mapContentRating("EROTICA") == .nsfw)
        #expect(MangaBakaMetadataProvider.mapContentRating("pornographic") == .nsfw)
        #expect(MangaBakaMetadataProvider.mapContentRating(nil) == nil)
        #expect(MangaBakaMetadataProvider.mapContentRating("") == nil)
        #expect(MangaBakaMetadataProvider.mapContentRating("unrecognized") == nil)

        let json = """
        {
          "status": 200,
          "data": {
            "id": 9001,
            "title": "Content Rating Series",
            "cover": { "raw": { "url": null } },
            "status": "releasing",
            "type": "manga",
            "content_rating": "erotica"
          }
        }
        """
        let response = try JSONDecoder().decode(
            MangaBakaResponse<MangaBakaSeries>.self,
            from: Data(json.utf8)
        )
        let series = try #require(response.data)
        let mapped = MangaBakaMetadataProvider.map(series: series, trackId: "9001")
        #expect(mapped.contentRating == .nsfw)

        let malformedJson = """
        {
          "status": 200,
          "data": {
            "id": 9002,
            "title": "Malformed Content Rating",
            "cover": { "raw": { "url": null } },
            "status": "releasing",
            "type": "manga",
            "content_rating": 42
          }
        }
        """
        let malformedResponse = try JSONDecoder().decode(
            MangaBakaResponse<MangaBakaSeries>.self,
            from: Data(malformedJson.utf8)
        )
        let malformedSeries = try #require(malformedResponse.data)
        let malformedMapped = MangaBakaMetadataProvider.map(series: malformedSeries, trackId: "9002")
        #expect(malformedMapped.contentRating == nil)
    }

    @Test func lenientlyDecodesMalformedExtendedFieldsWithoutBreakingSeries() throws {
        let json = """
        {
          "status": 200,
          "data": {
            "id": 777,
            "title": "Valid Series",
            "cover": { "raw": { "url": "https://images.mangabaka.dev/777/raw.jpg" } },
            "description": null,
            "status": "releasing",
            "type": "manga",
            "genres": 123,
            "titles": [
              null,
              123,
              "bad",
              { "language": "ja" },
              { "language": "en", "title": "Valid Title", "is_primary": true }
            ]
          }
        }
        """

        let response = try JSONDecoder().decode(
            MangaBakaResponse<MangaBakaSeries>.self,
            from: Data(json.utf8)
        )
        let series = try #require(response.data)
        #expect(series.title == "Valid Series")
        #expect(series.genres == nil)
        #expect(series.titles?.count == 1)
        #expect(series.titles?.first?.title == "Valid Title")
    }

    @Test func syntheticDefaultTitleDoesNotOutrankExplicitEnglishTitle() throws {
        let json = """
        {
          "status": 200,
          "data": {
            "id": 1995,
            "title": "Sousou no Frieren",
            "cover": { "raw": { "url": null } },
            "description": null,
            "status": "hiatus",
            "type": "manga",
            "titles": [
              { "language": "en", "title": "Frieren: Beyond Journey's End", "is_primary": false, "traits": [] }
            ]
          }
        }
        """

        let response = try JSONDecoder().decode(
            MangaBakaResponse<MangaBakaSeries>.self,
            from: Data(json.utf8)
        )
        let series = try #require(response.data)
        let mapped = MangaBakaMetadataProvider.map(series: series, trackId: "1995")

        let syntheticDefault = try #require(mapped.titleOptions.first { $0.title == "Sousou no Frieren" })
        #expect(syntheticDefault.languageCode == "unknown")
        #expect(!syntheticDefault.isPrimary)

        let resolved = TitleLanguagePriorityStore.resolvePreferredTitle(
            from: mapped.titleOptions,
            defaultTitle: mapped.defaultTitle,
            priorityOrder: ["en"]
        )
        #expect(resolved?.title == "Frieren: Beyond Journey's End")
    }

    @Test func decodesSourceLinksWithMixedIdsAndToleratesMalformedSource() throws {
        let validJson = """
        {
          "status": 200,
          "data": {
            "id": 1264,
            "title": "Grand Blue Dreaming",
            "cover": { "raw": { "url": "https://images.mangabaka.dev/cover.jpg" } },
            "status": "releasing",
            "type": "manga",
            "source": {
              "anilist": { "id": 87395, "rating": 8.9 },
              "my_anime_list": { "id": "70345" },
              "kitsu": { "id": 30463 },
              "manga_updates": { "id": "u63f9zm" }
            }
          }
        }
        """

        let response = try JSONDecoder().decode(
            MangaBakaResponse<MangaBakaSeries>.self,
            from: Data(validJson.utf8)
        )
        let series = try #require(response.data)
        #expect(series.source?.anilist?.id?.intValue == 87395)
        #expect(series.source?.myAnimeList?.id?.intValue == 70345)
        #expect(series.source?.kitsu?.id?.value == "30463")
        #expect(series.source?.mangaUpdates?.id?.value == "u63f9zm")

        let malformedSourceJson = """
        {
          "status": 200,
          "data": {
            "id": 1264,
            "title": "Grand Blue Dreaming",
            "cover": { "raw": { "url": null } },
            "status": "releasing",
            "type": "manga",
            "source": "unexpected-string"
          }
        }
        """
        let fallbackResponse = try JSONDecoder().decode(
            MangaBakaResponse<MangaBakaSeries>.self,
            from: Data(malformedSourceJson.utf8)
        )
        #expect(fallbackResponse.data?.title == "Grand Blue Dreaming")
        #expect(fallbackResponse.data?.source == nil)
    }

    @Test func decodesImagesResponseLenientlyAndDeduplicatesCoverGallery() throws {
        let json = """
        {
          "status": 200,
          "available_languages": ["ja", "zh-Hant-TW", 123, null],
          "available_types": ["volume", 456],
          "pagination": {
            "count": 3,
            "page": 1,
            "limit": 50,
            "next": null
          },
          "data": [
            null,
            { "bad": true },
            {
              "id": 101,
              "index": "1",
              "index_numeric": 1,
              "type": "volume",
              "language": "ja",
              "image": {
                "raw": { "url": "https://images.mangabaka.dev/main-cover.jpg" },
                "x250": {
                  "x1": "https://cdn.mangabaka.dev/x250@1/main.jpg",
                  "x2": "https://cdn.mangabaka.dev/x250@2/main.jpg"
                }
              }
            },
            {
              "id": 102,
              "index": 2,
              "index_numeric": 2,
              "type": "volume",
              "language": "zh-tw",
              "image": {
                "raw": { "url": "https://images.mangabaka.dev/vol2.jpg" },
                "x250": {
                  "x1": "https://cdn.mangabaka.dev/x250@1/vol2.jpg",
                  "x2": null
                }
              }
            }
          ]
        }
        """

        let decoded = try JSONDecoder().decode(MangaBakaImagesResponse.self, from: Data(json.utf8))
        #expect(decoded.availableLanguages == ["ja", "zh-Hant-TW"])
        #expect(decoded.availableTypes == ["volume"])

        let page = MangaBakaMetadataProvider.mapCoverPage(
            images: decoded.data ?? [],
            pagination: decoded.pagination,
            requestedPage: 1,
            availableLanguages: decoded.availableLanguages ?? [],
            requestedType: "volume"
        )
        #expect(page.covers.count == 2)
        #expect(page.covers[0].thumbnailUrl == "https://cdn.mangabaka.dev/x250@2/main.jpg")
        #expect(page.covers[1].volumeLabel == "2")
        #expect(page.covers[1].languageCode == "zh-Hant")
        #expect(page.covers[1].thumbnailUrl == "https://cdn.mangabaka.dev/x250@1/vol2.jpg")
        #expect(!page.hasNextPage)
        #expect(page.availableLanguages == ["ja", "zh-Hant-TW"])
        #expect(page.requestedType == "volume")

        let seriesJson = """
        {
          "status": 200,
          "data": {
            "id": 1264,
            "title": "Grand Blue",
            "cover": { "raw": { "url": "https://images.mangabaka.dev/main-cover.jpg" } },
            "status": "releasing",
            "type": "manga"
          }
        }
        """
        let series = try #require(
            try JSONDecoder().decode(MangaBakaResponse<MangaBakaSeries>.self, from: Data(seriesJson.utf8)).data
        )
        let mapped = MangaBakaMetadataProvider.map(
            series: series,
            trackId: "1264",
            initialCoverPage: page
        )
        #expect(mapped.coverOptions.count == 2)
        #expect(mapped.coverOptions.first?.isMain == true)
        #expect(mapped.totalCoverCount == 2)
        #expect(mapped.availableCoverLanguages == ["ja", "zh-Hant-TW"])
        #expect(mapped.initialCoverFilterType == "volume")
        #expect(mapped.hasLoadedInitialCovers)

        let failedInitialMap = MangaBakaMetadataProvider.map(
            series: series,
            trackId: "1264",
            initialCoverPage: nil
        )
        #expect(!failedInitialMap.hasLoadedInitialCovers)
    }

    @Test func buildSeriesImagesURLClampsLimitPageAndTrimsFilters() throws {
        let base = try #require(URL(string: "https://api.mangabaka.org"))
        let url = try MangaBakaApi.buildSeriesImagesURL(
            baseApiUrl: base,
            id: 1995,
            page: 0,
            limit: 120,
            type: " volume ",
            language: " zh-Hant-TW "
        )
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let map = Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { first, _ in first })
        #expect(url.path == "/v1/series/1995/images")
        #expect(map["page"] == "1")
        #expect(map["limit"] == "50")
        #expect(map["type"] == "volume")
        #expect(map["language"] == "zh-Hant-TW")

        let lowLimitUrl = try MangaBakaApi.buildSeriesImagesURL(
            baseApiUrl: base,
            id: 42,
            page: 2,
            limit: -5,
            type: "   ",
            language: nil
        )
        let lowItems = try #require(URLComponents(url: lowLimitUrl, resolvingAgainstBaseURL: false)?.queryItems)
        let lowMap = Dictionary(lowItems.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { first, _ in first })
        #expect(lowMap["page"] == "2")
        #expect(lowMap["limit"] == "1")
        #expect(lowMap["type"] == nil)
        #expect(lowMap["language"] == nil)
    }

    @Test func mapCoverPageCalculatesHasNextPageAndTotalCountFromPagination() {
        let nextPresent = MangaBakaMetadataProvider.mapCoverPage(
            images: [],
            pagination: MangaBakaPagination(count: 1, page: 1, limit: 50, next: "https://api.mangabaka.org/next"),
            requestedPage: 1
        )
        #expect(nextPresent.hasNextPage)

        let countExceedsPage = MangaBakaMetadataProvider.mapCoverPage(
            images: [],
            pagination: MangaBakaPagination(count: 75, page: 1, limit: 50, next: nil),
            requestedPage: 1
        )
        #expect(countExceedsPage.hasNextPage)
        #expect(countExceedsPage.totalCount == 75)

        let countFitsPage = MangaBakaMetadataProvider.mapCoverPage(
            images: [],
            pagination: MangaBakaPagination(count: 50, page: 1, limit: 50, next: nil),
            requestedPage: 1
        )
        #expect(!countFitsPage.hasNextPage)
        #expect(countFitsPage.totalCount == 50)

        let noPagination = MangaBakaMetadataProvider.mapCoverPage(
            images: [],
            pagination: nil,
            requestedPage: 1
        )
        #expect(!noPagination.hasNextPage)
        #expect(noPagination.totalCount == 0)
    }
}

@Suite struct MangaBakaCoverPickerTests {
    @MainActor
    @Test func coverPickerViewModelHandlesCachingRegionalChipsPaginationErrorsAndRaces() async {
        let provider = MockCoverGalleryProvider()
        let mainCover = TrackerCoverOption(
            id: "main",
            rawUrl: "https://images.mangabaka.dev/main.jpg",
            thumbnailUrl: "https://images.mangabaka.dev/main.jpg",
            volumeLabel: nil,
            type: "main",
            languageCode: "unknown",
            isMain: true
        )
        let vol1 = TrackerCoverOption(
            id: "v1",
            rawUrl: "https://images.mangabaka.dev/v1.jpg",
            thumbnailUrl: "https://cdn.mangabaka.dev/v1.jpg",
            volumeLabel: "1",
            type: "volume",
            languageCode: "ja",
            isMain: false
        )
        let metadata = TrackerMangaMetadata(
            trackerId: "mangabaka",
            trackerName: "MangaBaka",
            trackId: "1264",
            defaultTitle: "Grand Blue",
            titleOptions: [],
            coverUrl: mainCover.rawUrl,
            coverOptions: [mainCover, vol1],
            availableCoverLanguages: ["ja", "zh-hk", "zh-Hant-TW"],
            initialCoverFilterType: "volume",
            hasLoadedInitialCovers: true,
            totalCoverCount: 3,
            hasMoreCovers: true,
            authors: [],
            artists: [],
            status: .ongoing,
            description: nil,
            tags: []
        )

        let viewModel = MangaBakaCoverPickerViewModel(
            metadata: metadata,
            selectedCoverUrl: mainCover.rawUrl,
            metadataProvider: provider,
            priorityOrder: ["zh-Hant", "ja"]
        )

        #expect(viewModel.selectedTypeFilter == .volumes)
        #expect(viewModel.availableLanguages == ["zh-Hant-TW", "zh-hk", "ja"])
        #expect(viewModel.languageChipTitle(for: "zh-hk") == "繁中 (HK)")
        #expect(viewModel.languageChipTitle(for: "zh-Hant-TW") == "繁中 (TW)")
        #expect(viewModel.languageChipTitle(for: "ja") == "日本語")

        // Regional code is forwarded verbatim to API filter instead of collapsing to "zh-Hant".
        await provider.setHandler { _, _, type, language in
            if language == "zh-Hant-TW" {
                return TrackerCoverPage(
                    covers: [
                        TrackerCoverOption(
                            id: "tw1",
                            rawUrl: "https://images.mangabaka.dev/tw1.jpg",
                            thumbnailUrl: "https://cdn.mangabaka.dev/tw1.jpg",
                            volumeLabel: "1",
                            type: "volume",
                            languageCode: "zh-Hant",
                            isMain: false
                        )
                    ],
                    totalCount: 1,
                    page: 1,
                    hasNextPage: false,
                    requestedType: type
                )
            }
            return TrackerCoverPage(covers: [], totalCount: 0, page: 1, hasNextPage: false, requestedType: type)
        }

        await viewModel.selectLanguageFilter("zh-Hant-TW")
        #expect(viewModel.covers.map(\.rawUrl) == ["https://images.mangabaka.dev/tw1.jpg"])

        // Switching back to cached (volumes, nil) hits memory cache without another provider call.
        let callsBeforeCacheHit = await provider.recordedCalls.count
        await viewModel.selectLanguageFilter(nil)
        #expect(await provider.recordedCalls.count == callsBeforeCacheHit)
        #expect(viewModel.covers.map(\.id) == ["main", "v1"])

        // Pagination failure preserves hasNextPage and retryLoadMore recovers & deduplicates.
        await provider.setHandler { _, page, _, _ in
            if page == 2 {
                struct TemporaryError: LocalizedError {
                    var errorDescription: String? { "Temporary error" }
                }
                throw TemporaryError()
            }
            return TrackerCoverPage(covers: [], totalCount: 0, page: page, hasNextPage: false)
        }
        await viewModel.loadMoreIfNeeded(currentItem: vol1)
        #expect(viewModel.loadMoreErrorMessage == "Temporary error")
        #expect(viewModel.hasNextPage)

        let vol2 = TrackerCoverOption(
            id: "v2",
            rawUrl: "https://images.mangabaka.dev/v2.jpg",
            thumbnailUrl: "https://cdn.mangabaka.dev/v2.jpg",
            volumeLabel: "2",
            type: "volume",
            languageCode: "ja",
            isMain: false
        )
        await provider.setHandler { _, page, type, _ in
            TrackerCoverPage(
                covers: [vol1, vol2],
                totalCount: 3,
                page: page,
                hasNextPage: false,
                requestedType: type
            )
        }
        await viewModel.retryLoadMore()
        #expect(viewModel.loadMoreErrorMessage == nil)
        #expect(viewModel.covers.map(\.rawUrl) == [mainCover.rawUrl, vol1.rawUrl, vol2.rawUrl])
        #expect(!viewModel.hasNextPage)

        // Switching to an empty Volumes filter does NOT inject Main Cover.
        await provider.setHandler { _, page, type, _ in
            TrackerCoverPage(covers: [], totalCount: 0, page: page, hasNextPage: false, requestedType: type)
        }
        await viewModel.selectLanguageFilter("fr")
        #expect(viewModel.covers.isEmpty)
    }

    @MainActor
    @Test func coverPickerViewModelDiscardsStaleRaceIgnoresCancelAndRecoversInitialFailure() async {
        let provider = MockCoverGalleryProvider()
        let mainUrl = "https://images.mangabaka.dev/main.jpg"
        let banner = TrackerCoverOption(
            id: "b1",
            rawUrl: "https://images.mangabaka.dev/banner.jpg",
            thumbnailUrl: "https://cdn.mangabaka.dev/banner.jpg",
            volumeLabel: nil,
            type: "banner",
            languageCode: "en",
            isMain: false
        )

        let uncachedMetadata = TrackerMangaMetadata(
            trackerId: "mangabaka",
            trackerName: "MangaBaka",
            trackId: "1",
            defaultTitle: "Series 1",
            titleOptions: [],
            coverUrl: mainUrl,
            coverOptions: [
                TrackerCoverOption(
                    id: "main",
                    rawUrl: mainUrl,
                    thumbnailUrl: mainUrl,
                    volumeLabel: nil,
                    type: "main",
                    languageCode: "unknown",
                    isMain: true
                )
            ],
            availableCoverLanguages: [],
            initialCoverFilterType: nil,
            hasLoadedInitialCovers: false,
            totalCoverCount: 1,
            hasMoreCovers: false,
            authors: [],
            artists: [],
            status: .ongoing,
            description: nil,
            tags: []
        )

        await provider.setHandler { _, page, type, _ in
            if type == "volume" {
                return TrackerCoverPage(
                    covers: [],
                    totalCount: 0,
                    page: page,
                    hasNextPage: false,
                    availableLanguages: ["en"],
                    requestedType: "volume"
                )
            }
            return TrackerCoverPage(
                covers: [banner],
                totalCount: 1,
                page: page,
                hasNextPage: false,
                availableLanguages: ["en"],
                requestedType: nil
            )
        }

        let vm = MangaBakaCoverPickerViewModel(
            metadata: uncachedMetadata,
            selectedCoverUrl: mainUrl,
            metadataProvider: provider,
            priorityOrder: ["en"]
        )
        await vm.loadInitialIfNeeded()
        #expect(vm.selectedTypeFilter == .all)
        #expect(vm.covers.map(\.id) == ["main", "b1"])
        #expect(vm.availableLanguages == ["en"])

        // Generation race: start slow `.volumes`, then immediately switch to `.all` (cached -> immediate).
        await provider.setHandler { _, page, type, language in
            if language == "ja" {
                try await Task.sleep(nanoseconds: 120_000_000)
                return TrackerCoverPage(
                    covers: [
                        TrackerCoverOption(
                            id: "stale",
                            rawUrl: "https://images.mangabaka.dev/stale.jpg",
                            thumbnailUrl: "https://cdn.mangabaka.dev/stale.jpg",
                            volumeLabel: "9",
                            type: type ?? "other",
                            languageCode: "ja",
                            isMain: false
                        )
                    ],
                    totalCount: 1,
                    page: page,
                    hasNextPage: false,
                    requestedType: type
                )
            }
            return TrackerCoverPage(covers: [], totalCount: 0, page: page, hasNextPage: false, requestedType: type)
        }

        async let slowFetch: Void = vm.selectLanguageFilter("ja")
        try? await Task.sleep(nanoseconds: 10_000_000)
        await vm.selectLanguageFilter(nil)
        await slowFetch

        #expect(vm.selectedLanguageFilter == nil)
        #expect(!vm.covers.contains { $0.id == "stale" })

        // CancellationError does not set errorMessage.
        await provider.setHandler { _, _, _, _ in
            throw CancellationError()
        }
        await vm.selectLanguageFilter("ko")
        #expect(vm.errorMessage == nil)
    }
}

private actor MockCoverGalleryProvider: TrackerMetadataProvider {
    struct Call: Equatable {
        let trackId: String
        let page: Int
        let type: String?
        let language: String?
    }

    nonisolated let trackerId = "mangabaka"
    nonisolated let trackerName = "MangaBaka"

    private(set) var recordedCalls: [Call] = []
    private var handler: (@Sendable (String, Int, String?, String?) async throws -> TrackerCoverPage)?

    func setHandler(
        _ handler: @escaping @Sendable (String, Int, String?, String?) async throws -> TrackerCoverPage
    ) {
        self.handler = handler
    }

    func fetchMetadata(trackId: String) async throws -> TrackerMangaMetadata {
        fatalError("Unused in cover picker test")
    }

    func fetchCoverPage(
        trackId: String,
        page: Int,
        type: String?,
        language: String?
    ) async throws -> TrackerCoverPage {
        recordedCalls.append(Call(trackId: trackId, page: page, type: type, language: language))
        if let handler {
            return try await handler(trackId, page, type, language)
        }
        return TrackerCoverPage(covers: [], totalCount: 0, page: page, hasNextPage: false, requestedType: type)
    }
}
