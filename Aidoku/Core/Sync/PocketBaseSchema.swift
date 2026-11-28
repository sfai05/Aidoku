//
//  PocketBaseSchema.swift
//  Aidoku
//

import Foundation

struct PocketBaseFieldPayload: Codable, Equatable, Sendable {
    var name: String
    var type: String
    var required: Bool?
    var presentable: Bool?
    var system: Bool?
    var hidden: Bool?
    // relation
    var collectionId: String?
    var cascadeDelete: Bool?
    var minSelect: Int?
    var maxSelect: Int?
    // number
    var min: Double?
    var max: Double?
    var onlyInt: Bool?
    // text
    var pattern: String?
    // file
    var maxSize: Int?
    var mimeTypes: [String]?
    var protected: Bool?
    // autodate
    var onCreate: Bool?
    var onUpdate: Bool?
}

struct PocketBaseCollectionPayload: Codable, Equatable, Sendable {
    var name: String
    var type: String
    var system: Bool
    var listRule: String?
    var viewRule: String?
    var createRule: String?
    var updateRule: String?
    var deleteRule: String?
    var fields: [PocketBaseFieldPayload]
    var indexes: [String]

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(system, forKey: .system)
        try container.encode(listRule, forKey: .listRule)
        try container.encode(viewRule, forKey: .viewRule)
        try container.encode(createRule, forKey: .createRule)
        try container.encode(updateRule, forKey: .updateRule)
        try container.encode(deleteRule, forKey: .deleteRule)
        try container.encode(fields, forKey: .fields)
        try container.encode(indexes, forKey: .indexes)
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case type
        case system
        case listRule
        case viewRule
        case createRule
        case updateRule
        case deleteRule
        case fields
        case indexes
    }
}

enum PocketBaseSchema {
    static let defaultCollectionName = "dokuha_sync_snapshots"
    static let defaultUsersCollectionId = "_pb_users_auth_"
    static let maxPayloadSizeBytes = 52_428_800
    static let requiredFieldNames: Set<String> = [
        "owner",
        "revision",
        "device_id",
        "schema_version",
        "checksum",
        "payload"
    ]

    static func isValidCollectionName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        return name.range(of: #"^[A-Za-z][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }

    static func collectionPayload(
        collectionName: String = defaultCollectionName,
        usersCollectionId: String = defaultUsersCollectionId
    ) -> PocketBaseCollectionPayload {
        PocketBaseCollectionPayload(
            name: collectionName,
            type: "base",
            system: false,
            listRule: "@request.auth.id != \"\" && owner = @request.auth.id",
            viewRule: "@request.auth.id != \"\" && owner = @request.auth.id",
            createRule: "@request.auth.id != \"\" && @request.body.owner = @request.auth.id",
            updateRule: nil,
            deleteRule: "@request.auth.id != \"\" && owner = @request.auth.id",
            fields: [
                PocketBaseFieldPayload(
                    name: "owner",
                    type: "relation",
                    required: true,
                    collectionId: usersCollectionId,
                    cascadeDelete: true,
                    maxSelect: 1
                ),
                PocketBaseFieldPayload(
                    name: "revision",
                    type: "number",
                    required: true,
                    presentable: true,
                    min: 1,
                    onlyInt: true
                ),
                PocketBaseFieldPayload(
                    name: "device_id",
                    type: "text",
                    required: true
                ),
                PocketBaseFieldPayload(
                    name: "device_name",
                    type: "text",
                    required: false
                ),
                PocketBaseFieldPayload(
                    name: "schema_version",
                    type: "number",
                    required: true,
                    min: 1,
                    onlyInt: true
                ),
                PocketBaseFieldPayload(
                    name: "checksum",
                    type: "text",
                    required: true
                ),
                PocketBaseFieldPayload(
                    name: "payload",
                    type: "file",
                    required: true,
                    maxSelect: 1,
                    maxSize: maxPayloadSizeBytes,
                    protected: true
                ),
                PocketBaseFieldPayload(
                    name: "created",
                    type: "autodate",
                    onCreate: true,
                    onUpdate: false
                ),
                PocketBaseFieldPayload(
                    name: "updated",
                    type: "autodate",
                    onCreate: true,
                    onUpdate: true
                )
            ],
            indexes: [
                "CREATE UNIQUE INDEX idx_\(collectionName)_owner_revision ON \(collectionName) (owner, revision)"
            ]
        )
    }

    static func exportSchemaJSON(
        collectionName: String = defaultCollectionName,
        usersCollectionId: String = defaultUsersCollectionId
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = [collectionPayload(collectionName: collectionName, usersCollectionId: usersCollectionId)]
        let data = try encoder.encode(payload)
        guard let string = String(data: data, encoding: .utf8) else {
            throw SyncError.persistenceError("Unable to encode PocketBase schema as UTF-8.")
        }
        return string
    }
}
