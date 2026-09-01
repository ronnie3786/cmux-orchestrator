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

    var label: String {
        switch self {
        case .queued: "Queued"
        case .running: "Thinking"
        case .completed: "Answered"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .promoted: "Continued as chat"
        }
    }
}

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

struct HeadlessAgentAttachment: Encodable, Equatable, Sendable {
    let filename: String
    let dataBase64: String
}

struct HeadlessAgentStartRequest: Encodable, Sendable {
    let prompt: String
    let mode: HeadlessAgentRunMode
    let model: String?
    let thinkingLevel: String?
    let attachments: [HeadlessAgentAttachment]?

    init(
        prompt: String,
        mode: HeadlessAgentRunMode = .ask,
        model: String? = nil,
        thinkingLevel: String? = nil,
        attachments: [HeadlessAgentAttachment]? = nil
    ) {
        self.prompt = prompt
        self.mode = mode
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey {
        case prompt, mode, model, thinkingLevel, attachments
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(prompt, forKey: .prompt)
        if mode != .ask {
            try container.encode(mode, forKey: .mode)
        }
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(thinkingLevel, forKey: .thinkingLevel)
        if let attachments, !attachments.isEmpty {
            try container.encode(attachments, forKey: .attachments)
        }
    }
}

struct HeadlessAgentPromotionRequest: Encodable, Sendable {
    let workspaceID: String?
    let cwd: String?
    let workspaceLabel: String?

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspaceId"
        case cwd
        case workspaceLabel
    }
}
