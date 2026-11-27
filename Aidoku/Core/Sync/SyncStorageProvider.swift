//
//  SyncStorageProvider.swift
//  Aidoku
//

import Foundation

struct SyncSnapshotMetadata: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let revision: Int
    let deviceId: String
    let deviceName: String
    let schemaVersion: Int
    let checksum: String
    let fileName: String
    let sizeBytes: Int?
    let createdAt: Date
    let updatedAt: Date
}

struct SyncHealthStatus: Equatable, Sendable {
    let isReachable: Bool
    let isAuthenticated: Bool
    let collectionReady: Bool
    let message: String
    let serverVersion: String?

    var isHealthy: Bool {
        isReachable && isAuthenticated && collectionReady
    }
}

struct SyncUploadRequest: Sendable {
    let revision: Int
    let deviceId: String
    let deviceName: String
    let schemaVersion: Int
    let checksum: String
    let fileName: String
    let data: Data
}

protocol SyncStorageProvider: Sendable {
    var providerId: String { get }

    func refreshSessionIfNeeded() async throws
    func healthCheck() async throws -> SyncHealthStatus
    func fetchLatestMetadata() async throws -> SyncSnapshotMetadata?
    func downloadSnapshot(metadata: SyncSnapshotMetadata) async throws -> Data
    func uploadSnapshot(_ request: SyncUploadRequest) async throws -> SyncSnapshotMetadata
    func listSnapshots(limit: Int) async throws -> [SyncSnapshotMetadata]
    func deleteSnapshot(id: String) async throws
}

extension SyncStorageProvider {
    func refreshSessionIfNeeded() async throws {}
}
