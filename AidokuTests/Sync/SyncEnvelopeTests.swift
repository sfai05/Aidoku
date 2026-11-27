//
//  SyncEnvelopeTests.swift
//  AidokuTests
//

@testable import Aidoku
import Foundation
import Testing

@Suite struct SyncEnvelopeTests {
    @Test func gzipRoundTripAndChecksum() throws {
        let backup = SyncTestFixtures.makeBackup(
            library: [SyncTestFixtures.makeLibraryManga(mangaId: "m1", categories: ["Favorites"])],
            history: [SyncTestFixtures.makeHistory(mangaId: "m1", chapterId: "c1", completed: true)],
            manga: [SyncTestFixtures.makeManga(id: "m1", title: "One Piece")],
            categories: [SyncTestFixtures.makeCategory(title: "Favorites", sort: 0)],
            sourceLists: ["https://aidoku.app/list.json"],
            settings: ["Reader.readingMode": .string("vertical")]
        )
        let tombstones = SyncTombstones(
            libraryManga: [SyncMangaTombstone(sourceId: "mangadex", mangaId: "deleted-1", deletedAt: SyncTestFixtures.date(1_234.5))],
            history: [SyncHistoryTombstone(sourceId: "mangadex", mangaId: "m1", chapterId: "c0", deletedAt: SyncTestFixtures.date(1_500.25))]
        )
        let envelope = SyncEnvelope(
            revision: 4,
            deviceId: "ipad-1",
            deviceName: "iPad Pro",
            updatedAt: SyncTestFixtures.date(2_500.75),
            tombstones: tombstones,
            backup: backup
        )

        let encoded = try SyncEnvelopeCodec.encode(envelope, compress: true)
        #expect(encoded.count > 18)
        #expect(encoded[0] == 0x1f)
        #expect(encoded[1] == 0x8b)

        let decoded = try SyncEnvelopeCodec.decode(encoded)
        #expect(decoded.schemaVersion == SyncEnvelope.currentSchemaVersion)
        #expect(decoded.revision == 4)
        #expect(decoded.deviceId == "ipad-1")
        #expect(decoded.deviceName == "iPad Pro")
        #expect(decoded.tombstones == tombstones)
        #expect(decoded.backup.manga?.first?.title == "One Piece")
        #expect(decoded.backup.history?.first?.completed == true)
        #expect(decoded.backup.settings?["Reader.readingMode"] == .string("vertical"))

        let digest1 = SyncEnvelopeCodec.sha256Hex(encoded)
        let digest2 = SyncEnvelopeCodec.sha256Hex(encoded)
        #expect(digest1.count == 64)
        #expect(digest1 == digest2)
    }

    @Test func uncompressedJSONDecodeFallback() throws {
        let envelope = SyncEnvelope(
            revision: 2,
            deviceId: "iphone-1",
            deviceName: "iPhone",
            updatedAt: SyncTestFixtures.date(1_000),
            tombstones: .empty,
            backup: SyncTestFixtures.makeBackup()
        )
        let raw = try SyncEnvelopeCodec.encode(envelope, compress: false)
        #expect(raw.first != 0x1f)

        let decoded = try SyncEnvelopeCodec.decode(raw)
        #expect(decoded == envelope)
    }

    @Test func corruptedGzipTrailerIsRejected() throws {
        let envelope = SyncEnvelope(
            revision: 1,
            deviceId: "d1",
            deviceName: "Device",
            backup: SyncTestFixtures.makeBackup(manga: [SyncTestFixtures.makeManga()])
        )
        var encoded = try SyncEnvelopeCodec.encode(envelope, compress: true)
        encoded[encoded.count - 1] ^= 0xff

        #expect {
            _ = try SyncEnvelopeCodec.decode(encoded)
        } throws: { error in
            guard case SyncError.corruptedSnapshot = error else { return false }
            return true
        }
    }

    @Test func unsupportedSchemaVersionIsRejected() throws {
        let envelope = SyncEnvelope(
            schemaVersion: 99,
            revision: 1,
            deviceId: "d1",
            deviceName: "Device",
            backup: SyncTestFixtures.makeBackup()
        )
        let encoded = try SyncEnvelopeCodec.encode(envelope, compress: false)

        #expect {
            _ = try SyncEnvelopeCodec.decode(encoded)
        } throws: { error in
            error as? SyncError == .unsupportedSchemaVersion(99)
        }
    }

    @Test func forkSyncKeysAreExcludedFromBackupAndSyncSettings() {
        let prefix = SyncConfiguration.Key.prefix
        let containsPrefix = BackupManager.allowedSettingsPrefixes.contains { prefix.hasPrefix($0) }
        #expect(!containsPrefix)
        #expect(!SyncMerger.isAllowedSyncSettingKey(SyncConfiguration.Key.serverURL))
        #expect(!SyncMerger.isAllowedSyncSettingKey(SyncConfiguration.Key.enabled))
        #expect(!SyncMerger.isAllowedSyncSettingKey("Fork.secretFlag"))
        #expect(!SyncMerger.isAllowedSyncSettingKey("Tracker.anilist.token"))
        #expect(!SyncMerger.isAllowedSyncSettingKey(AppSettings.general.icloudSync.key))
        #expect(SyncMerger.isAllowedSyncSettingKey("Reader.readingMode"))
    }
}
