//
//  MetadataEnrichmentTests.swift
//  AidokuTests
//

@testable import Aidoku
import Foundation
import Testing

@Suite struct MetadataEnrichmentTests {
    @Test func parseAniListStaffSplitsAuthorsAndArtistsAndExcludesSecondaryRoles() {
        let grandBlueJson = """
        {
          "data": {
            "Media": {
              "staff": {
                "edges": [
                  { "role": "Story", "node": { "name": { "full": "Kenji Inoue", "native": "井上堅二" } } },
                  { "role": "Art", "node": { "name": { "full": "Kimitake Yoshioka", "native": "吉岡公威" } } },
                  { "role": "Translator (English)", "node": { "name": { "full": "Adam Hirsch", "native": null } } },
                  { "role": "Lettering (English)", "node": { "name": { "full": "Jan Ivan", "native": null } } }
                ]
              }
            }
          }
        }
        """
        let grandBlue = MetadataEnrichmentService.parseAniListStaff(data: Data(grandBlueJson.utf8))
        #expect(grandBlue.authors == ["井上堅二"])
        #expect(grandBlue.artists == ["吉岡公威"])

        let mixedJson = """
        {
          "data": {
            "Media": {
              "staff": {
                "edges": [
                  { "role": "Story & Art (vols 1-41)", "node": { "name": { "full": "Kentarou Miura", "native": "三浦建太郎 " } } },
                  { "role": "Story & Art (vols 41- )", "node": { "name": { "full": "Studio Gaga", "native": "スタジオ我画" } } },
                  { "role": "Original Story", "node": { "name": { "full": "Chu-Gong", "native": "추공" } } },
                  { "role": "Art (chs 180-200)", "node": { "name": { "full": "DISCIPLES", "native": null } } },
                  { "role": "Supervisor (vols 41- )", "node": { "name": { "full": "Kouji Mori", "native": "森恒二" } } },
                  { "role": "Assistant (Former)", "node": { "name": { "full": "Ryou Ishiyama", "native": "石山諒" } } },
                  { "role": "Editing (2020-2023)", "node": { "name": { "full": "Yuuji Iwasaki", "native": "岩崎湧治" } } },
                  { "role": "Touch-up Art & Lettering", "node": { "name": { "full": "Dan Nakrosis", "native": null } } }
                ]
              }
            }
          }
        }
        """
        let mixed = MetadataEnrichmentService.parseAniListStaff(data: Data(mixedJson.utf8))
        #expect(mixed.authors == ["三浦建太郎", "スタジオ我画", "추공"])
        #expect(mixed.artists == ["三浦建太郎", "スタジオ我画", "DISCIPLES"])
    }

    @Test func parseMangaDexDescriptionsRequiresCrossIdMatchAndNormalizesChineseCodes() {
        let json = """
        {
          "data": [
            {
              "attributes": {
                "links": { "al": "999999", "mal": "888888" },
                "description": {
                  "en": "Wrong series match.",
                  "zh-hk": "錯誤的作品簡介。"
                }
              }
            },
            {
              "attributes": {
                "links": { "al": "118586", "mal": "126287" },
                "description": {
                  "zh-hk": "繁體中文簡介。\\r\\n第二行。",
                  "zh-cn": "简体中文简介。",
                  "en": "English synopsis.",
                  "fr": "   "
                }
              }
            }
          ]
        }
        """

        let sourceLinks = MangaBakaSeries.SourceLinks(
            anilist: .init(id: FlexibleStringID("118586")),
            myAnimeList: .init(id: FlexibleStringID("126287"))
        )

        let options = MetadataEnrichmentService.parseMangaDexDescriptions(
            data: Data(json.utf8),
            sourceLinks: sourceLinks
        )

        #expect(options.count == 3)
        #expect(options.contains(TrackerDescriptionOption(
            languageCode: "zh-Hant",
            text: "繁體中文簡介。\n第二行。",
            sourceName: "MangaDex"
        )))
        #expect(options.contains(TrackerDescriptionOption(
            languageCode: "zh-Hans",
            text: "简体中文简介。",
            sourceName: "MangaDex"
        )))
        #expect(!options.contains { $0.text.contains("Wrong series") })

        // Never matches if MangaBaka lacks cross-reference IDs.
        let withoutIds = MetadataEnrichmentService.parseMangaDexDescriptions(
            data: Data(json.utf8),
            sourceLinks: nil
        )
        #expect(withoutIds.isEmpty)
    }

    @Test func parseBangumiDescriptionsMatchesSeriesExcludesVolumesAndInfersLanguage() {
        let json = """
        {
          "data": [
            {
              "name": "葬送のフリーレン",
              "name_cn": "葬送的芙莉莲",
              "platform": "漫画",
              "series": true,
              "summary": "中文简介正文。\\r\\n在打倒了魔王之后。"
            },
            {
              "name": "葬送のフリーレン (1)",
              "name_cn": "",
              "platform": "漫画",
              "series": false,
              "summary": "Single volume description should be skipped."
            },
            {
              "name": "葬送のフリーレン",
              "name_cn": "葬送的芙莉莲",
              "platform": "小说",
              "series": true,
              "summary": "Novel adaptation should be skipped for manga."
            },
            {
              "name": "ぐらんぶる",
              "name_cn": "GRANDBLUE",
              "platform": "漫画",
              "series": true,
              "summary": "海沿いの街で一人暮らしを始めた北原伊織は衝撃の大学デビューを果たす。"
            }
          ]
        }
        """

        let frierenOptions = MetadataEnrichmentService.parseBangumiDescriptions(
            data: Data(json.utf8),
            knownTitles: ["Frieren: Beyond Journey's End", "葬送のフリーレン"],
            isNovel: false
        )
        #expect(frierenOptions.count == 2)
        #expect(frierenOptions.contains(TrackerDescriptionOption(
            languageCode: "zh",
            text: "中文简介正文。\n在打倒了魔王之后。",
            sourceName: "Bangumi"
        )))
        #expect(frierenOptions.contains(TrackerDescriptionOption(
            languageCode: "zh-Hant",
            text: "中文簡介正文。\n在打倒了魔王之後。",
            sourceName: "Bangumi"
        )))

        let grandBlueOptions = MetadataEnrichmentService.parseBangumiDescriptions(
            data: Data(json.utf8),
            knownTitles: ["Grand Blue Dreaming", "ぐらんぶる"],
            isNovel: false
        )
        #expect(grandBlueOptions.count == 1)
        #expect(grandBlueOptions.first?.languageCode == "ja")
        #expect(!grandBlueOptions.contains { $0.languageCode == "zh-Hant" })
    }

    @Test func convertsBangumiSimplifiedChineseToTraditionalAndPreservesSourcePriority() throws {
        let converted = MetadataEnrichmentService.convertSimplifiedToTraditional(
            "后宫、头发、皇后、面条、里面、图书馆"
        )
        #expect(converted == "後宮、頭髮、皇后、麵條、裡面、圖書館")

        let asciiJson = """
        {
          "data": [
            {
              "name": "Test Series",
              "name_cn": "Test Series",
              "platform": "漫画",
              "series": true,
              "summary": "English only summary"
            }
          ]
        }
        """
        let asciiOptions = MetadataEnrichmentService.parseBangumiDescriptions(
            data: Data(asciiJson.utf8),
            knownTitles: ["Test Series"],
            isNovel: false
        )
        #expect(asciiOptions.count == 1)
        #expect(asciiOptions.first?.languageCode == "zh")

        let bangumiOnlyJson = """
        {
          "data": [
            {
              "name": "葬送のフリーレン",
              "platform": "漫画",
              "series": true,
              "summary": "勇者一行人回到王都之后。"
            }
          ]
        }
        """
        let bangumiOptions = MetadataEnrichmentService.parseBangumiDescriptions(
            data: Data(bangumiOnlyJson.utf8),
            knownTitles: ["葬送のフリーレン"],
            isNovel: false
        )
        let preferredFromBangumi = TitleLanguagePriorityStore.resolvePreferredDescription(
            from: bangumiOptions,
            priorityOrder: ["zh-Hant", "zh", "en"]
        )
        #expect(preferredFromBangumi?.languageCode == "zh-Hant")
        #expect(preferredFromBangumi?.text == "勇者一行人回到王都之後。")
        #expect(preferredFromBangumi?.sourceName == "Bangumi")

        let nativeDex = TrackerDescriptionOption(
            languageCode: "zh-Hant",
            text: "MangaDex 原生繁中簡介。",
            sourceName: "MangaDex"
        )
        let combined = bangumiOptions + [nativeDex]
        let preferredWithNative = TitleLanguagePriorityStore.resolvePreferredDescription(
            from: combined,
            priorityOrder: ["zh-Hant", "zh", "en"]
        )
        #expect(preferredWithNative == nativeDex)

        let quickWithNative = TitleLanguagePriorityStore.quickDescriptionOptions(
            from: combined,
            priorityOrder: ["zh-Hant", "zh", "en"],
            limit: 4
        )
        #expect(quickWithNative.first(where: { $0.languageCode == "zh-Hant" }) == nativeDex)

        let mbOption = TrackerDescriptionOption(languageCode: "en", text: "MB EN", sourceName: "MangaBaka")
        let sorted = TitleLanguagePriorityStore.sortDescriptionOptions(
            combined + [mbOption],
            priorityOrder: ["zh-Hant", "zh", "en"]
        )
        #expect(sorted.map { "\($0.languageCode):\($0.sourceName)" } == [
            "zh-Hant:MangaDex",
            "zh-Hant:Bangumi",
            "zh:Bangumi",
            "en:MangaBaka"
        ])

        // Already-Traditional Bangumi summary still yields zh-Hant so zh-Hant-only priority matches it.
        let tradBangumiJson = """
        {
          "data": [
            {
              "name": "傳統簡介漫畫",
              "platform": "漫画",
              "series": true,
              "summary": "繁體中文劇情。"
            }
          ]
        }
        """
        let tradOptions = MetadataEnrichmentService.parseBangumiDescriptions(
            data: Data(tradBangumiJson.utf8),
            knownTitles: ["傳統簡介漫畫"],
            isNovel: false
        )
        #expect(TitleLanguagePriorityStore.resolvePreferredDescription(
            from: tradOptions,
            priorityOrder: ["zh-Hant", "en"]
        )?.languageCode == "zh-Hant")

        // When Bangumi converted zh-Hant matches MangaDex native zh-Hant text verbatim, MangaDex wins dedupe.
        let seriesJson = """
        {
          "status": 200,
          "data": {
            "id": 1995,
            "title": "Test",
            "cover": { "raw": { "url": null } },
            "status": "releasing",
            "type": "manga"
          }
        }
        """
        let series = try #require(
            try JSONDecoder().decode(MangaBakaResponse<MangaBakaSeries>.self, from: Data(seriesJson.utf8)).data
        )
        let sameDex = TrackerDescriptionOption(languageCode: "zh-Hant", text: "共同繁中簡介。", sourceName: "MangaDex")
        let sameBangumi = TrackerDescriptionOption(languageCode: "zh-Hant", text: "共同繁中簡介。", sourceName: "Bangumi")
        let mapped = MangaBakaMetadataProvider.map(
            series: series,
            trackId: "1995",
            externalDescriptions: [sameDex, sameBangumi]
        )
        let hantOptions = mapped.descriptionOptions.filter { $0.languageCode == "zh-Hant" }
        #expect(hantOptions == [sameDex])
    }

    @Test func titleLanguagePriorityStoreResolvesAndRanksLocalizedDescriptions() {
        let options = [
            TrackerDescriptionOption(languageCode: "en", text: "MangaDex EN", sourceName: "MangaDex"),
            TrackerDescriptionOption(languageCode: "en", text: "MangaBaka EN", sourceName: "MangaBaka"),
            TrackerDescriptionOption(languageCode: "zh", text: "Bangumi ZH", sourceName: "Bangumi"),
            TrackerDescriptionOption(languageCode: "zh-Hant", text: "MangaDex ZH-HK", sourceName: "MangaDex"),
            TrackerDescriptionOption(languageCode: "ja", text: "Bangumi JA", sourceName: "Bangumi")
        ]

        let zhHantFirst = TitleLanguagePriorityStore.resolvePreferredDescription(
            from: options,
            priorityOrder: ["zh-Hant", "zh", "en"]
        )
        #expect(zhHantFirst?.languageCode == "zh-Hant")
        #expect(zhHantFirst?.sourceName == "MangaDex")

        let enTieBreak = TitleLanguagePriorityStore.resolvePreferredDescription(
            from: options,
            priorityOrder: ["fr", "de"]
        )
        #expect(enTieBreak?.languageCode == "en")
        #expect(enTieBreak?.sourceName == "MangaBaka")

        let quick = TitleLanguagePriorityStore.quickDescriptionOptions(
            from: options,
            priorityOrder: ["zh-Hant", "ja", "zh", "en"],
            limit: 4
        )
        #expect(quick.map(\.languageCode) == ["zh-Hant", "ja", "zh", "en"])
    }

    @Test func normalizesRegionalChineseCodesConsistently() {
        #expect(TitleLanguagePriorityStore.normalizeRegionLanguageCode("zh-tw") == "zh-Hant")
        #expect(TitleLanguagePriorityStore.normalizeRegionLanguageCode("zh-hk") == "zh-Hant")
        #expect(TitleLanguagePriorityStore.normalizeRegionLanguageCode("zh-mo") == "zh-Hant")
        #expect(TitleLanguagePriorityStore.normalizeRegionLanguageCode("zh_HK") == "zh-Hant")
        #expect(TitleLanguagePriorityStore.normalizeRegionLanguageCode("zh-Hant-TW") == "zh-Hant")
        #expect(TitleLanguagePriorityStore.normalizeRegionLanguageCode("zh-Hant-HK") == "zh-Hant")
        #expect(TitleLanguagePriorityStore.normalizeRegionLanguageCode("zh-cn") == "zh-Hans")
        #expect(TitleLanguagePriorityStore.normalizeRegionLanguageCode("zh-sg") == "zh-Hans")
        #expect(TitleLanguagePriorityStore.normalizeRegionLanguageCode("zh_CN") == "zh-Hans")
        #expect(TitleLanguagePriorityStore.normalizeRegionLanguageCode("zh-Hans-CN") == "zh-Hans")
    }

    @Test func infersBangumiLanguageAtThresholdAndHandlesErrorPayloads() {
        #expect(MetadataEnrichmentService.inferBangumiLanguage(for: "") == "zh")
        #expect(MetadataEnrichmentService.inferBangumiLanguage(for: "   \n\t ") == "zh")
        // Exact 0.1 kana ratio (1 kana out of 10 non-whitespace chars) stays "zh" (> 0.1 required).
        #expect(MetadataEnrichmentService.inferBangumiLanguage(for: "あabcdefghi") == "zh")
        // Above 0.1 kana ratio (2 kana out of 10 non-whitespace chars) becomes "ja".
        #expect(MetadataEnrichmentService.inferBangumiLanguage(for: "あアabcdefgh") == "ja")

        let errorsOnlyJson = """
        { "errors": [{ "message": "Not Found", "status": 404 }], "data": { "Media": null } }
        """
        let emptyStaff = MetadataEnrichmentService.parseAniListStaff(data: Data(errorsOnlyJson.utf8))
        #expect(emptyStaff.authors.isEmpty)
        #expect(emptyStaff.artists.isEmpty)

        // Case-insensitive Kitsu/MangaUpdates cross-ID matching + ignores empty IDs.
        let dexJson = """
        {
          "data": [
            {
              "attributes": {
                "links": { "al": "", "mu": "U63F9ZM", "kt": "" },
                "description": {
                  "en": "Matched by MU.",
                  "zh-hk": "粵語簡介。"
                }
              }
            }
          ]
        }
        """
        let links = MangaBakaSeries.SourceLinks(
            anilist: .init(id: FlexibleStringID("  ")),
            mangaUpdates: .init(id: FlexibleStringID("u63f9zm"))
        )
        let matched = MetadataEnrichmentService.parseMangaDexDescriptions(
            data: Data(dexJson.utf8),
            sourceLinks: links
        )
        #expect(matched.map(\.languageCode) == ["en", "zh-Hant"])
    }
}

@Suite(.serialized)
struct MetadataEnrichmentNetworkTests {
    @Test func mangaDexSendsExpandedQueryParamsAndDegradesGracefullyOnErrors() async throws {
        EnrichmentURLProtocolStub.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EnrichmentURLProtocolStub.self]
        let session = URLSession(configuration: config)
        let service = MetadataEnrichmentService(session: session)

        let seriesJson = """
        {
          "status": 200,
          "data": {
            "id": 1995,
            "title": "Frieren",
            "native_title": "葬送のフリーレン",
            "cover": { "raw": { "url": null } },
            "status": "hiatus",
            "type": "manga",
            "source": {
              "anilist": { "id": 118586 }
            }
          }
        }
        """
        let series = try #require(
            try JSONDecoder().decode(MangaBakaResponse<MangaBakaSeries>.self, from: Data(seriesJson.utf8)).data
        )

        EnrichmentURLProtocolStub.handler = { request in
            let url = request.url!
            if url.host == "api.mangadex.org" {
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                #expect(items.contains(URLQueryItem(name: "limit", value: "20")))
                #expect(items.contains(URLQueryItem(name: "contentRating[]", value: "safe")))
                #expect(items.contains(URLQueryItem(name: "contentRating[]", value: "suggestive")))
                #expect(items.contains(URLQueryItem(name: "contentRating[]", value: "erotica")))
                #expect(items.contains(URLQueryItem(name: "contentRating[]", value: "pornographic")))
                let body = """
                {
                  "data": [
                    {
                      "attributes": {
                        "links": { "al": "118586" },
                        "description": { "zh-tw": "繁體簡介", "en": "Shared text" }
                      }
                    }
                  ]
                }
                """
                return (200, Data(body.utf8))
            }
            if url.host == "api.bgm.tv" {
                let body = """
                {
                  "data": [
                    {
                      "name": "葬送のフリーレン",
                      "platform": "漫画",
                      "series": true,
                      "summary": "中文简介"
                    }
                  ]
                }
                """
                return (200, Data(body.utf8))
            }
            return (500, Data("error".utf8))
        }

        let descriptions = await service.fetchLocalizedDescriptions(for: series)
        #expect(descriptions.count == 4)
        #expect(descriptions.contains { $0.sourceName == "MangaDex" && $0.languageCode == "zh-Hant" })
        #expect(descriptions.contains { $0.sourceName == "Bangumi" && $0.languageCode == "zh" })
        #expect(descriptions.contains {
            $0.sourceName == "Bangumi" && $0.languageCode == "zh-Hant" && $0.text == "中文簡介"
        })

        // Verify graceful degradation on HTTP 429 / 500 and malformed JSON.
        EnrichmentURLProtocolStub.handler = { request in
            if request.url?.host == "api.mangadex.org" {
                return (429, Data("rate limited".utf8))
            }
            if request.url?.host == "api.bgm.tv" {
                return (200, Data("not valid json".utf8))
            }
            return (500, Data())
        }

        let dex429 = await service.fetchMangaDexDescriptions(query: "Frieren", sourceLinks: series.source)
        #expect(dex429.isEmpty)
        let bgmMalformed = await service.fetchBangumiDescriptions(
            keyword: "Frieren",
            knownTitles: ["Frieren"],
            isNovel: false
        )
        #expect(bgmMalformed.isEmpty)
        let anilist500 = await service.fetchAniListNativeStaff(anilistId: 118586)
        #expect(anilist500.authors.isEmpty && anilist500.artists.isEmpty)
    }
}

private final class EnrichmentURLProtocolStub: URLProtocol {
    private static let lock = NSLock()
    private static var _handler: ((URLRequest) -> (Int, Data))?

    static var handler: ((URLRequest) -> (Int, Data))? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _handler
        }
        set {
            lock.lock()
            _handler = newValue
            lock.unlock()
        }
    }

    static func reset() {
        handler = nil
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (status, data) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
