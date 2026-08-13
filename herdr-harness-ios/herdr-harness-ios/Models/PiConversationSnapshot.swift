import Foundation

struct PiConversationSnapshot: Decodable, Equatable, Sendable {
    let ok: Bool
    let protocolInfo: PiProtocolInfo
    let paneID: String
    let available: Bool
    let connected: Bool
    let session: PiJSONValue?
    let state: PiJSONValue?
    let entries: [PiJSONValue]
    let pendingInteractions: [PiJSONValue]
    let cursor: String?
    let oldestCursor: String?
    let truncated: Bool
    let generatedAt: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case protocolInfo = "protocol"
        case paneID
        case paneIDCamel = "paneId"
        case paneIDSnake = "pane_id"
        case available
        case connected
        case session
        case state
        case entries
        case pendingInteractions
        case pendingInteractionsSnake = "pending_interactions"
        case cursor
        case oldestCursor
        case oldestCursorSnake = "oldest_cursor"
        case truncated
        case generatedAt
        case generatedAtSnake = "generated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        protocolInfo = try container.decodeIfPresent(PiProtocolInfo.self, forKey: .protocolInfo)
            ?? PiProtocolInfo(name: "herdr.pi.semantic", version: 1)
        paneID = try container.decodeIfPresent(String.self, forKey: .paneID)
            ?? container.decodeIfPresent(String.self, forKey: .paneIDCamel)
            ?? container.decodeIfPresent(String.self, forKey: .paneIDSnake)
            ?? ""
        available = try container.decodeIfPresent(Bool.self, forKey: .available) ?? true
        connected = try container.decodeIfPresent(Bool.self, forKey: .connected) ?? false
        session = try container.decodeIfPresent(PiJSONValue.self, forKey: .session)
        state = try container.decodeIfPresent(PiJSONValue.self, forKey: .state)
        entries = try container.decodeIfPresent([PiJSONValue].self, forKey: .entries) ?? []
        pendingInteractions = try container.decodeIfPresent([PiJSONValue].self, forKey: .pendingInteractions)
            ?? container.decodeIfPresent([PiJSONValue].self, forKey: .pendingInteractionsSnake)
            ?? []
        cursor = try Self.decodeCursor(container, keys: [.cursor])
        oldestCursor = try Self.decodeCursor(container, keys: [.oldestCursor, .oldestCursorSnake])
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        generatedAt = try container.decodeIfPresent(String.self, forKey: .generatedAt)
            ?? container.decodeIfPresent(String.self, forKey: .generatedAtSnake)
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
