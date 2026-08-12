import ActivityKit
import Foundation

/// The only state Herdr exposes outside the app. Keep this payload aggregate-only:
/// Live Activities are visible on an unlocked screen, paired devices, and StandBy.
struct HerdPulseAttributes: ActivityAttributes, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        let workspaceCount: Int
        let paneCount: Int
        let workingCount: Int
        let attentionCount: Int
        let readyCount: Int
        let connection: HerdPulseConnection
        let phase: HerdPulsePhase
        let updatedAt: Int
    }

    let pulseID: String
    let startedAt: Int
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
