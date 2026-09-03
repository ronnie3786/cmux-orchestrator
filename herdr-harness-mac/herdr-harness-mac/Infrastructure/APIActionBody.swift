import Foundation

struct APIActionBody: Encodable, Sendable {
    var text: String?
    var label: String?
    var cwd: String?
    var direction: String?
    var ratio: Double?
    var keys: [String]?
    var submit: Bool?
    var kind: String?
    var name: String?
    var command: String?
    var mode: String?
    var wait: Bool?
    var until: String?
    var timeoutMs: Int?

    init(
        text: String? = nil,
        label: String? = nil,
        cwd: String? = nil,
        direction: String? = nil,
        ratio: Double? = nil,
        keys: [String]? = nil,
        submit: Bool? = nil,
        kind: String? = nil,
        name: String? = nil,
        command: String? = nil,
        mode: String? = nil,
        wait: Bool? = nil,
        until: String? = nil,
        timeoutMs: Int? = nil
    ) {
        self.text = text
        self.label = label
        self.cwd = cwd
        self.direction = direction
        self.ratio = ratio
        self.keys = keys
        self.submit = submit
        self.kind = kind
        self.name = name
        self.command = command
        self.mode = mode
        self.wait = wait
        self.until = until
        self.timeoutMs = timeoutMs
    }
}

struct PiSetModelBody: Encodable, Sendable {
    let provider: String
    let id: String
}

struct PiSetThinkingLevelBody: Encodable, Sendable {
    let level: String
}

struct ActiveWorkIngestionBody: Encodable, Sendable {
    struct Selector: Encodable, Sendable {
        let workItemID: String

        enum CodingKeys: String, CodingKey {
            case workItemID = "work_item_id"
        }
    }

    struct Session: Encodable, Sendable {
        var externalID: String
        var title: String
        var provider: String
        var status: String
        var machineID: String
        var workspaceID: String
        var paneID: String
        var nativeSessionID: String
        var role: String
        var metadata: [String: String]

        enum CodingKeys: String, CodingKey {
            case externalID = "external_id"
            case title
            case provider
            case status
            case machineID = "machine_id"
            case workspaceID = "workspace_id"
            case paneID = "pane_id"
            case nativeSessionID = "native_session_id"
            case role
            case metadata
        }
    }

    struct Stage: Encodable, Sendable {
        var stageKey: String
        var state: String
        var piSessions: [Session]

        enum CodingKeys: String, CodingKey {
            case stageKey = "stage_key"
            case state
            case piSessions = "pi_sessions"
        }
    }

    let source: String
    let idempotencyKey: String
    let observedAt: String
    let selector: Selector
    let stages: [Stage]

    enum CodingKeys: String, CodingKey {
        case source
        case idempotencyKey = "idempotency_key"
        case observedAt = "observed_at"
        case selector
        case stages
    }
}
