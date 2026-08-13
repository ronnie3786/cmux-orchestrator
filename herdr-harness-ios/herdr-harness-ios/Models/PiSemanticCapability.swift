import Foundation

struct PiSemanticCapability: Codable, Equatable, Hashable, Sendable {
    let available: Bool
    let connected: Bool
    let protocolVersion: Int
    let sessionID: String?
    let cursor: String?
    let oldestCursor: String?
    let capabilities: PiSemanticCapabilities
    let generatedAt: String?

    enum CodingKeys: String, CodingKey {
        case available
        case connected
        case protocolVersion
        case protocolVersionSnake = "protocol_version"
        case sessionID
        case sessionIDCamel = "sessionId"
        case sessionIDSnake = "session_id"
        case cursor
        case oldestCursor
        case oldestCursorSnake = "oldest_cursor"
        case capabilities
        case generatedAt
        case generatedAtSnake = "generated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        available = try container.decodeIfPresent(Bool.self, forKey: .available) ?? false
        connected = try container.decodeIfPresent(Bool.self, forKey: .connected) ?? false
        protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion)
            ?? container.decodeIfPresent(Int.self, forKey: .protocolVersionSnake)
            ?? 0
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
            ?? container.decodeIfPresent(String.self, forKey: .sessionIDCamel)
            ?? container.decodeIfPresent(String.self, forKey: .sessionIDSnake)
        cursor = try Self.decodeCursor(container, keys: [.cursor])
        oldestCursor = try Self.decodeCursor(container, keys: [.oldestCursor, .oldestCursorSnake])
        capabilities = try container.decodeIfPresent(PiSemanticCapabilities.self, forKey: .capabilities)
            ?? PiSemanticCapabilities.unavailable
        generatedAt = try container.decodeIfPresent(String.self, forKey: .generatedAt)
            ?? container.decodeIfPresent(String.self, forKey: .generatedAtSnake)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(available, forKey: .available)
        try container.encode(connected, forKey: .connected)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encodeIfPresent(sessionID, forKey: .sessionIDCamel)
        try container.encodeIfPresent(cursor, forKey: .cursor)
        try container.encodeIfPresent(oldestCursor, forKey: .oldestCursor)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encodeIfPresent(generatedAt, forKey: .generatedAt)
    }

    private static func decodeCursor(
        _ container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) throws -> String? {
        for key in keys {
            if let value = try? container.decodeIfPresent(String.self, forKey: key) { return value }
            if let value = try? container.decodeIfPresent(Int64.self, forKey: key) { return String(value) }
        }
        return nil
    }
}
