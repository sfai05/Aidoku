//
//  SyncEnvelopeCodec.swift
//  Aidoku
//

import CryptoKit
import Foundation

enum SyncEnvelopeCodec {
    private static let gzipMagic0: UInt8 = 0x1f
    private static let gzipMagic1: UInt8 = 0x8b
    private static let gzipDeflateMethod: UInt8 = 0x08

    static func encode(_ envelope: SyncEnvelope, compress: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let rawJSON = try encoder.encode(envelope)
        guard compress else {
            return rawJSON
        }
        return try gzipCompress(rawJSON)
    }

    static func decode(_ data: Data) throws -> SyncEnvelope {
        guard !data.isEmpty else {
            throw SyncError.corruptedSnapshot("Snapshot payload is empty.")
        }

        let jsonData: Data
        if data.count >= 2 && data[data.startIndex] == gzipMagic0 && data[data.index(after: data.startIndex)] == gzipMagic1 {
            jsonData = try gzipDecompress(data)
        } else {
            jsonData = data
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let envelope: SyncEnvelope
        do {
            envelope = try decoder.decode(SyncEnvelope.self, from: jsonData)
        } catch {
            throw SyncError.corruptedSnapshot("Unable to decode snapshot JSON: \(error.localizedDescription)")
        }

        guard envelope.schemaVersion <= SyncEnvelope.currentSchemaVersion else {
            throw SyncError.unsupportedSchemaVersion(envelope.schemaVersion)
        }
        guard envelope.schemaVersion >= 1 else {
            throw SyncError.unsupportedSchemaVersion(envelope.schemaVersion)
        }

        return envelope
    }

    static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func gzipCompress(_ data: Data) throws -> Data {
        let compressedPayload: Data
        do {
            compressedPayload = try (data as NSData).compressed(using: .zlib) as Data
        } catch {
            throw SyncError.corruptedSnapshot("Failed to compress snapshot: \(error.localizedDescription)")
        }

        var output = Data(capacity: 10 + compressedPayload.count + 8)
        // RFC 1952 fixed 10-byte GZIP header (ID1, ID2, CM=deflate, FLG=0, MTIME=0, XFL=0, OS=unknown)
        output.append(contentsOf: [gzipMagic0, gzipMagic1, gzipDeflateMethod, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        output.append(compressedPayload)

        let crc = crc32(data)
        var crcLE = crc.littleEndian
        withUnsafeBytes(of: &crcLE) { output.append(contentsOf: $0) }

        var sizeLE = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &sizeLE) { output.append(contentsOf: $0) }

        return output
    }

    static func gzipDecompress(_ data: Data) throws -> Data {
        guard data.count >= 18 else {
            throw SyncError.corruptedSnapshot("Gzip stream is too short.")
        }

        let bytes = [UInt8](data)
        guard bytes[0] == gzipMagic0, bytes[1] == gzipMagic1, bytes[2] == gzipDeflateMethod else {
            throw SyncError.corruptedSnapshot("Invalid Gzip header.")
        }

        let flags = bytes[3]
        var offset = 10

        // FEXTRA (bit 2)
        if flags & 0x04 != 0 {
            guard offset + 2 <= bytes.count else {
                throw SyncError.corruptedSnapshot("Truncated Gzip FEXTRA length.")
            }
            let xlen = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2 + xlen
        }

        // FNAME (bit 3)
        if flags & 0x08 != 0 {
            guard let nullIndex = bytes[offset...].firstIndex(of: 0) else {
                throw SyncError.corruptedSnapshot("Unterminated Gzip FNAME.")
            }
            offset = nullIndex + 1
        }

        // FCOMMENT (bit 4)
        if flags & 0x10 != 0 {
            guard let nullIndex = bytes[offset...].firstIndex(of: 0) else {
                throw SyncError.corruptedSnapshot("Unterminated Gzip FCOMMENT.")
            }
            offset = nullIndex + 1
        }

        // FHCRC (bit 1)
        if flags & 0x02 != 0 {
            offset += 2
        }

        let trailerLength = 8
        guard offset < bytes.count - trailerLength else {
            throw SyncError.corruptedSnapshot("Missing Gzip trailer.")
        }

        let payloadRange = offset..<(bytes.count - trailerLength)
        let compressedSlice = Data(bytes[payloadRange])
        let decompressed: Data
        do {
            decompressed = try (compressedSlice as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw SyncError.corruptedSnapshot("Failed to decompress Gzip payload: \(error.localizedDescription)")
        }

        let trailerStart = bytes.count - trailerLength
        let expectedCRC = UInt32(bytes[trailerStart])
            | (UInt32(bytes[trailerStart + 1]) << 8)
            | (UInt32(bytes[trailerStart + 2]) << 16)
            | (UInt32(bytes[trailerStart + 3]) << 24)
        let expectedSize = UInt32(bytes[trailerStart + 4])
            | (UInt32(bytes[trailerStart + 5]) << 8)
            | (UInt32(bytes[trailerStart + 6]) << 16)
            | (UInt32(bytes[trailerStart + 7]) << 24)

        let actualCRC = crc32(decompressed)
        let actualSize = UInt32(truncatingIfNeeded: decompressed.count)
        guard actualCRC == expectedCRC, actualSize == expectedSize else {
            throw SyncError.corruptedSnapshot("Gzip CRC32 or length verification failed.")
        }

        return decompressed
    }

    private static let crc32Table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                if value & 1 == 1 {
                    value = 0xedb8_8320 ^ (value >> 1)
                } else {
                    value >>= 1
                }
            }
            return value
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            let tableIndex = Int((crc ^ UInt32(byte)) & 0xff)
            crc = crc32Table[tableIndex] ^ (crc >> 8)
        }
        return crc ^ 0xffff_ffff
    }
}
