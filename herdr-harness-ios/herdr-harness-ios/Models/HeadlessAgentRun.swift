import Foundation

enum HeadlessAgentRunStatus: String, Codable, Sendable {
    case queued
    case running
    case completed
    case failed
    case cancelled
    case promoted

    var isTerminal: Bool {
        switch self {
        case .queued, .running:
            false
        case .completed, .failed, .cancelled, .promoted:
            true
        }
    }

    /// Do-shaped wording. The Mac twin says "Thinking"/"Answered" because its
    /// sheet leads with Ask; iOS only ever runs the agent, so the labels
    /// describe work rather than a reply.
    var label: String {
        switch self {
        case .queued: "Queued"
        case .running: "Working"
        case .completed: "Done"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .promoted: "Continued as chat"
        }
    }
}

/// The harness speaks both modes and so does iOS: the agent sheet sends `.act`
/// — the Do path — while the Pi session summary sends `.ask` because it only
/// ever reads. A run fetched back can report either, so both cases stay
/// decodable rather than making a stale payload fail the whole poll.
enum HeadlessAgentRunMode: String, Codable, Sendable {
    case ask
    case act
}

struct HeadlessAgentRun: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let status: HeadlessAgentRunStatus
    let mode: HeadlessAgentRunMode?
    let model: String?
    let thinkingLevel: String?
    let prompt: String
    let response: String?
    let error: String?
    let createdAt: String
    let startedAt: String?
    let finishedAt: String?
    let sessionID: String?
    let sessionFile: String?
    let costUSD: Double?
    let promotedWorkspaceID: String?
    let promotedPaneID: String?
    let attachments: [String]?
    let steps: [HeadlessAgentStep]?
    let stepsTruncated: Bool?
    let threadRootRunId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case mode
        case model
        case thinkingLevel
        case prompt
        case response
        case error
        case createdAt
        case startedAt
        case finishedAt
        case sessionID = "sessionId"
        case sessionFile
        case costUSD
        case promotedWorkspaceID = "promotedWorkspaceId"
        case promotedPaneID = "promotedPaneId"
        case attachments
        case steps
        case stepsTruncated
        case threadRootRunId
    }
}

struct HeadlessAgentStep: Codable, Equatable, Sendable {
    let toolCallId: String?
    let toolName: String?
    let argsPreview: String?
    let resultPreview: String?
    let isError: Bool?
    let startedAt: String?
    let finishedAt: String?
    let truncated: Bool?
}

struct HeadlessAgentRunEnvelope: Decodable, Sendable {
    let ok: Bool
    let run: HeadlessAgentRun
}

struct HeadlessAgentPromotionResult: Sendable {
    let run: HeadlessAgentRun
    let pane: HerdrPane
}

/// The agent sheet is the Do path, so `.act` is the default and every existing
/// caller keeps its wire shape. The Pi session summary is the one read-only
/// caller: it reads a transcript it does not trust, so it must not be handed
/// write tools.
///
/// The harness treats a missing `mode` as "ask", so `.ask` omits the key
/// exactly like the Mac's encoder does rather than inventing a second spelling.
struct HeadlessAgentStartRequest: Encodable, Sendable {
    let prompt: String
    let mode: HeadlessAgentRunMode
    let model: String?
    let thinkingLevel: String?

    init(
        prompt: String,
        mode: HeadlessAgentRunMode = .act,
        model: String?,
        thinkingLevel: String?
    ) {
        self.prompt = prompt
        self.mode = mode
        self.model = model
        self.thinkingLevel = thinkingLevel
    }

    private enum CodingKeys: String, CodingKey {
        case prompt, mode, model, thinkingLevel
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(prompt, forKey: .prompt)
        if mode != .ask {
            try container.encode(mode, forKey: .mode)
        }
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(thinkingLevel, forKey: .thinkingLevel)
    }
}

/// The Mac also sends `cwd` and `workspaceLabel` here for its "promote into a
/// brand new workspace" flow. iOS promotes into an existing workspace or into
/// Quick chats, so only the target id is on the wire.
struct HeadlessAgentPromotionRequest: Encodable, Sendable {
    let workspaceID: String?

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspaceId"
    }
}

/// Defaults the Mac keeps in `AgentModelSettings`. iOS needs exactly one of
/// them: the thinking level a fresh install runs at. There is no iOS surface
/// for changing it yet, so it is a constant rather than a stored preference.
enum HeadlessAgentRunDefaults {
    static let thinkingLevel = PiThinkingLevel.max
}

/// Identifies an open agent sheet. One machine, one sheet — the machine is
/// picked at the entry point, so the sheet itself never has to.
struct HeadlessAgentRequest: Identifiable, Equatable, Sendable {
    let machineID: String
    var id: String { machineID }
}
