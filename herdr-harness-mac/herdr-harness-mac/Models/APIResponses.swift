import Foundation

struct WorkspacesResponse: Decodable, Sendable {
    let ok: Bool
    let workspaces: [HerdrWorkspace]
    let alerts: [HerdrAlert]
    let generatedAt: String?
    let starredPaneIDs: [String]?

    enum CodingKeys: String, CodingKey {
        case ok
        case workspaces
        case alerts
        case generatedAt
        case generatedAtSnake = "generated_at"
        case starredPaneIDs = "starredPaneIds"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        workspaces = try container.decodeIfPresent([HerdrWorkspace].self, forKey: .workspaces) ?? []
        alerts = try container.decodeIfPresent([HerdrAlert].self, forKey: .alerts) ?? []
        generatedAt = try container.decodeIfPresent(String.self, forKey: .generatedAt)
            ?? container.decodeIfPresent(String.self, forKey: .generatedAtSnake)
        starredPaneIDs = try container.decodeIfPresent([String].self, forKey: .starredPaneIDs)
    }
}

struct HealthProbeResponse: Decodable, Sendable {
    let ok: Bool

    enum CodingKeys: String, CodingKey {
        case ok
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = (try? container.decodeIfPresent(Bool.self, forKey: .ok)) ?? true
    }
}

struct NetworkInfoResponse: Decodable, Sendable {
    let ok: Bool
    let hostname: String
    let tailscaleDNSName: String

    enum CodingKeys: String, CodingKey {
        case ok
        case hostname
        case tailscale
    }

    private struct Tailscale: Decodable, Sendable {
        let dnsName: String

        enum CodingKeys: String, CodingKey {
            case dnsName
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            dnsName = (try? container.decodeIfPresent(String.self, forKey: .dnsName)) ?? ""
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = (try? container.decodeIfPresent(Bool.self, forKey: .ok)) ?? true
        hostname = (try? container.decodeIfPresent(String.self, forKey: .hostname)) ?? ""
        tailscaleDNSName = (try? container.decodeIfPresent(Tailscale.self, forKey: .tailscale))?.dnsName ?? ""
    }
}

struct QuickPiSessionResponse: Decodable, Sendable {
    let ok: Bool
    let workspaceID: String
    let tabID: String
    let paneID: String
    let createdWorkspace: Bool
    let createdTab: Bool
    let createdPane: Bool
    let piExtensionAttached: Bool
    let requestID: String?
    let sessionID: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case paneID = "pane_id"
        case createdWorkspace = "created_workspace"
        case createdTab = "created_tab"
        case createdPane = "created_pane"
        case piExtensionAttached = "pi_extension_attached"
        case requestID = "request_id"
        case sessionID = "session_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        workspaceID = try container.decode(String.self, forKey: .workspaceID)
        tabID = try container.decode(String.self, forKey: .tabID)
        paneID = try container.decode(String.self, forKey: .paneID)
        createdWorkspace = try container.decode(Bool.self, forKey: .createdWorkspace)
        createdTab = try container.decode(Bool.self, forKey: .createdTab)
        createdPane = try container.decode(Bool.self, forKey: .createdPane)
        piExtensionAttached = try container.decode(Bool.self, forKey: .piExtensionAttached)
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        guard ok,
              !workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !tabID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !paneID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              createdPane
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Quick Pi placement is incomplete")
            )
        }
    }
}

struct AgentPromptDefaultsResponse: Decodable, Sendable {
    let ok: Bool
    let prompts: [String: String]
}

struct QuickPiSessionRequest: Encodable, Sendable {
    let label: String
    let requestID: String
    let workspaceID: String?
    let tabID: String?
    let cwd: String?
    let sessionFile: String?
    let sessionID: String?
    let workspaceLabel: String?
    let tabLabel: String?
    let reuseNamedTab: Bool?

    enum CodingKeys: String, CodingKey {
        case label
        case requestID = "requestId"
        case workspaceID = "workspaceId"
        case tabID = "tabId"
        case cwd
        case sessionFile
        case sessionID
        case workspaceLabel
        case tabLabel
        case reuseNamedTab
    }
}

struct AlertsResponse: Decodable, Sendable {
    let ok: Bool
    let alerts: [HerdrAlert]
    let unreadCount: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        alerts = try container.decodeIfPresent([HerdrAlert].self, forKey: .alerts) ?? []
        unreadCount = try container.decodeIfPresent(Int.self, forKey: .unreadCount)
            ?? alerts.count(where: { !$0.isRead })
    }

    private enum CodingKeys: String, CodingKey {
        case ok
        case alerts
        case unreadCount
    }
}

struct PaneOutputResponse: Decodable, Sendable {
    let ok: Bool
    let paneID: String
    let text: String
    let revision: Int
    let truncated: Bool

    init(ok: Bool, paneID: String, text: String, revision: Int, truncated: Bool) {
        self.ok = ok
        self.paneID = paneID
        self.text = text
        self.revision = revision
        self.truncated = truncated
    }

    enum CodingKeys: String, CodingKey {
        case ok
        case output
        case read
        case paneID = "pane_id"
        case text
        case revision
        case truncated
    }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: CodingKeys.self)
        ok = try root.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        let nested = try root.decodeIfPresent(PaneReadPayload.self, forKey: .output)
            ?? root.decodeIfPresent(PaneReadPayload.self, forKey: .read)
        let rootPaneID = try root.decodeIfPresent(String.self, forKey: .paneID)
        let rootText = try root.decodeIfPresent(String.self, forKey: .text)
        let rootRevision = try root.decodeIfPresent(Int.self, forKey: .revision)
        let rootTruncated = try root.decodeIfPresent(Bool.self, forKey: .truncated)
        paneID = nested?.paneID ?? rootPaneID ?? ""
        text = nested?.text ?? rootText ?? ""
        revision = nested?.revision ?? rootRevision ?? 0
        truncated = nested?.truncated ?? rootTruncated ?? false
    }
}

private struct PaneReadPayload: Decodable, Sendable {
    let paneID: String
    let text: String
    let revision: Int
    let truncated: Bool

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case text
        case revision
        case truncated
    }
}

struct MutationResponse: Decodable, Sendable {
    let ok: Bool
}

struct SplitPaneResponse: Decodable, Sendable {
    let ok: Bool
    let paneID: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case paneID = "paneId"
    }
}

struct PushStatusResponse: Decodable, Sendable {
    struct APNsStatus: Decodable, Sendable {
        let configured: Bool
    }

    let ok: Bool
    let apns: APNsStatus
}

struct HerdrEvent: Decodable, Equatable, Sendable {
    let id: Int?
    let event: String
    let data: JSONValue?

    init(id: Int? = nil, event: String, data: JSONValue?) {
        self.id = id
        self.event = event
        self.data = data
    }

    enum CodingKeys: String, CodingKey {
        case id, event, data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let numericID = try container.decodeIfPresent(Int.self, forKey: .id) {
            id = numericID
        } else if let stringID = try container.decodeIfPresent(String.self, forKey: .id) {
            id = Int(stringID)
        } else {
            id = nil
        }
        event = try container.decodeIfPresent(String.self, forKey: .event) ?? "message"
        data = try container.decodeIfPresent(JSONValue.self, forKey: .data)
    }
}

struct TerminalFrame: Decodable, Equatable, Sendable {
    let bytes: String
    let encoding: String
    let full: Bool
    let height: Int
    let sequence: Int
    let type: String
    let width: Int

    enum CodingKeys: String, CodingKey {
        case bytes
        case encoding
        case full
        case height
        case sequence = "seq"
        case type
        case width
    }

    init(
        bytes: String,
        encoding: String,
        full: Bool,
        height: Int,
        sequence: Int,
        type: String,
        width: Int
    ) {
        self.bytes = bytes
        self.encoding = encoding
        self.full = full
        self.height = height
        self.sequence = sequence
        self.type = type
        self.width = width
    }
}

enum TerminalStreamEvent: Equatable, Sendable {
    case ready
    case activity
    case frame(TerminalFrame)
}

enum JSONValue: Decodable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }
}
