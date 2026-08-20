import Foundation

struct PiConversationEnvelope: Decodable, Equatable, Sendable {
    let protocolInfo: PiProtocolInfo
    let paneID: String
    let sessionID: String?
    let cursor: String?
    let connected: Bool?
    let event: PiJSONValue
    let generatedAt: String?

    var eventType: String {
        event.string(for: "type") ?? "unknown"
    }

    enum CodingKeys: String, CodingKey {
        case protocolInfo = "protocol"
        case paneID
        case paneIDCamel = "paneId"
        case paneIDSnake = "pane_id"
        case sessionID
        case sessionIDCamel = "sessionId"
        case sessionIDSnake = "session_id"
        case cursor
        case connected
        case event
        case generatedAt
        case generatedAtSnake = "generated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolInfo = try container.decodeIfPresent(PiProtocolInfo.self, forKey: .protocolInfo)
            ?? PiProtocolInfo(name: "herdr.pi.semantic", version: 1)
        paneID = try container.decodeIfPresent(String.self, forKey: .paneID)
            ?? container.decodeIfPresent(String.self, forKey: .paneIDCamel)
            ?? container.decodeIfPresent(String.self, forKey: .paneIDSnake)
            ?? ""
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
            ?? container.decodeIfPresent(String.self, forKey: .sessionIDCamel)
            ?? container.decodeIfPresent(String.self, forKey: .sessionIDSnake)
        if let value = try? container.decodeIfPresent(String.self, forKey: .cursor) {
            cursor = value
        } else if let value = try? container.decodeIfPresent(Int64.self, forKey: .cursor) {
            cursor = String(value)
        } else {
            cursor = nil
        }
        connected = try container.decodeIfPresent(Bool.self, forKey: .connected)
        event = try container.decode(PiJSONValue.self, forKey: .event)
        generatedAt = try container.decodeIfPresent(String.self, forKey: .generatedAt)
            ?? container.decodeIfPresent(String.self, forKey: .generatedAtSnake)
    }

    init(
        protocolInfo: PiProtocolInfo = PiProtocolInfo(name: "herdr.pi.semantic", version: 1),
        paneID: String,
        sessionID: String?,
        cursor: String?,
        connected: Bool? = nil,
        event: PiJSONValue,
        generatedAt: String? = nil
    ) {
        self.protocolInfo = protocolInfo
        self.paneID = paneID
        self.sessionID = sessionID
        self.cursor = cursor
        self.connected = connected
        self.event = event
        self.generatedAt = generatedAt
    }

    func withCursor(_ fallbackCursor: String?) -> PiConversationEnvelope {
        guard cursor == nil, fallbackCursor != nil else { return self }
        return PiConversationEnvelope(
            protocolInfo: protocolInfo,
            paneID: paneID,
            sessionID: sessionID,
            cursor: fallbackCursor,
            connected: connected,
            event: event,
            generatedAt: generatedAt
        )
    }
}
