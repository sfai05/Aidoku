//
//  SyncLogStore.swift
//  Aidoku
//

import Foundation

enum SyncLogLevel: String, Codable, Sendable {
    case info
    case warning
    case error
}

struct SyncLogEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: SyncLogLevel
    let category: String
    let message: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: SyncLogLevel,
        category: String,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
    }
}

actor SyncLogStore {
    static let shared = SyncLogStore()

    private let fileURL: URL
    private let maxEntries: Int
    private var cachedEntries: [SyncLogEntry]?

    init(
        fileURL: URL = FileManager.default.applicationSupportDirectory
            .appendingPathComponent("ForkSync", isDirectory: true)
            .appendingPathComponent("sync_logs.json"),
        maxEntries: Int = 300
    ) {
        self.fileURL = fileURL
        self.maxEntries = max(1, maxEntries)
    }

    func log(level: SyncLogLevel, category: String, message: String) {
        var list = loadEntriesIfNeeded()
        let sanitizedMessage = Self.redactSecrets(message)
        let entry = SyncLogEntry(level: level, category: category, message: sanitizedMessage)
        list.append(entry)
        if list.count > maxEntries {
            list.removeFirst(list.count - maxEntries)
        }
        cachedEntries = list
        persist(list)

        switch level {
            case .info:
                LogManager.logger.info("[Sync:\(category)] \(sanitizedMessage)")
            case .warning:
                LogManager.logger.warn("[Sync:\(category)] \(sanitizedMessage)")
            case .error:
                LogManager.logger.error("[Sync:\(category)] \(sanitizedMessage)")
        }
    }

    func entries() -> [SyncLogEntry] {
        loadEntriesIfNeeded().reversed()
    }

    func clear() {
        cachedEntries = []
        fileURL.removeItem()
    }

    func exportText() -> String {
        let formatter = ISO8601DateFormatter()
        return loadEntriesIfNeeded()
            .map { entry in
                "[\(formatter.string(from: entry.timestamp))] [\(entry.level.rawValue.uppercased())] [\(entry.category)] \(entry.message)"
            }
            .joined(separator: "\n")
    }

    static func redactSecrets(_ text: String) -> String {
        var result = text
        let patterns: [(String, String)] = [
            // JWT tokens (header.payload.signature)
            (#"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}"#, "<REDACTED_JWT>"),
            // Authorization headers
            (#"(?i)(authorization\s*:\s*(?:bearer\s+)?)[^\s,;\"']+"#, "$1<REDACTED>"),
            // Embedded URL userinfo credentials
            (#"(?i)(https?://)[^/\s@]+@"#, "$1<REDACTED>@"),
            // Query parameter tokens (?token=... or &token=...)
            (#"(?i)([?&](?:token|auth|password)=)[^&\s]+"#, "$1<REDACTED>"),
            // JSON password / token fields
            (#"(?i)(\"(?:password|token|secret)\"\s*:\s*\")[^\"]*(\")"#, "$1<REDACTED>$2")
        ]

        for (pattern, replacement) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
            }
        }
        return result
    }

    private func loadEntriesIfNeeded() -> [SyncLogEntry] {
        if let cachedEntries {
            return cachedEntries
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            cachedEntries = []
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = (try? decoder.decode([SyncLogEntry].self, from: data)) ?? []
        cachedEntries = decoded
        return decoded
    }

    private func persist(_ entries: [SyncLogEntry]) {
        let directory = fileURL.deletingLastPathComponent()
        directory.createDirectory()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
