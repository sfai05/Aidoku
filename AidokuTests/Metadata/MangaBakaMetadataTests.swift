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
}
