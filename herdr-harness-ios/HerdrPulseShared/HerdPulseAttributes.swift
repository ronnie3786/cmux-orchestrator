import ActivityKit
import Foundation

/// The state Herdr exposes outside the app: aggregate counts always, plus a capped,
/// opt-in list of working, blocked, and done-unread session titles. The list mirrors
/// the acknowledgement state of `POST /api/v1/panes/{paneId}/alerts/read`.
struct HerdPulseAttributes: ActivityAttributes, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        struct Session: Codable, Hashable, Sendable, Identifiable {
            let id: String
            let title: String
            let agent: String
            let state: HerdPulseSessionState
            let since: Int
        }

        let workspaceCount: Int
        let paneCount: Int
        let workingCount: Int
        let attentionCount: Int
        let readyCount: Int
        let connection: HerdPulseConnection
        let phase: HerdPulsePhase
        let updatedAt: Int
        let sessions: [Session]
        let sessionOverflow: Int

        enum CodingKeys: String, CodingKey {
            case workspaceCount
            case paneCount
            case workingCount
            case attentionCount
            case readyCount
            case connection
            case phase
            case updatedAt
            case sessions
            case sessionOverflow
        }

        init(
            workspaceCount: Int,
            paneCount: Int,
            workingCount: Int,
            attentionCount: Int,
            readyCount: Int,
            connection: HerdPulseConnection,
            phase: HerdPulsePhase,
            updatedAt: Int,
            sessions: [Session] = [],
            sessionOverflow: Int = 0
        ) {
            self.workspaceCount = workspaceCount
            self.paneCount = paneCount
            self.workingCount = workingCount
            self.attentionCount = attentionCount
            self.readyCount = readyCount
            self.connection = connection
            self.phase = phase
            self.updatedAt = updatedAt
            self.sessions = sessions
            self.sessionOverflow = sessionOverflow
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            workspaceCount = try container.decode(Int.self, forKey: .workspaceCount)
            paneCount = try container.decode(Int.self, forKey: .paneCount)
            workingCount = try container.decode(Int.self, forKey: .workingCount)
            attentionCount = try container.decode(Int.self, forKey: .attentionCount)
            readyCount = try container.decode(Int.self, forKey: .readyCount)
            connection = try container.decode(HerdPulseConnection.self, forKey: .connection)
            phase = try container.decode(HerdPulsePhase.self, forKey: .phase)
            updatedAt = try container.decode(Int.self, forKey: .updatedAt)
            sessions = try container.decodeIfPresent([Session].self, forKey: .sessions) ?? []
            sessionOverflow = try container.decodeIfPresent(Int.self, forKey: .sessionOverflow) ?? 0
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(workspaceCount, forKey: .workspaceCount)
            try container.encode(paneCount, forKey: .paneCount)
            try container.encode(workingCount, forKey: .workingCount)
            try container.encode(attentionCount, forKey: .attentionCount)
            try container.encode(readyCount, forKey: .readyCount)
            try container.encode(connection, forKey: .connection)
            try container.encode(phase, forKey: .phase)
            try container.encode(updatedAt, forKey: .updatedAt)
            try container.encode(sessions, forKey: .sessions)
            try container.encode(sessionOverflow, forKey: .sessionOverflow)
        }
    }

    let pulseID: String
    let startedAt: Int
}

enum HerdPulseSessionState: String, Codable, Hashable, Sendable {
    case blocked
    case done
    case working
}

enum HerdPulseConnection: String, Codable, Hashable, Sendable {
    case live
    case reconnecting
    case demo
    case offline
}

enum HerdPulsePhase: String, Codable, Hashable, Sendable {
    case attention
    case ready
    case working
    case resting
    case offline
}
