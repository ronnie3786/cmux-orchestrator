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

struct HeadlessAgentRun: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let status: HeadlessAgentRunStatus
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

    enum CodingKeys: String, CodingKey {
        case id
        case status
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
    }
}

struct HeadlessAgentRunEnvelope: Decodable, Sendable {
    let ok: Bool
    let run: HeadlessAgentRun
}

struct HeadlessAgentPromotionResult: Sendable {
    let run: HeadlessAgentRun
    let pane: HerdrPane
}

struct HeadlessAgentStartRequest: Encodable, Sendable {
    let prompt: String
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
