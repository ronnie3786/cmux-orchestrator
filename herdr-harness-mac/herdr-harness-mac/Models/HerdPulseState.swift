import Foundation

/// Herdr exposes aggregate counts always, plus a capped, opt-in list of working,
/// blocked, and done-unread session titles for Live Activities. That list mirrors
/// `POST /api/v1/panes/{paneId}/alerts/read`; this Mac menu-bar payload remains
/// aggregate-only because it is visible in screen shares, recordings, and screenshots.
///
/// This aggregate subset is extracted from `HerdrPulseShared/HerdPulseAttributes.swift`
/// without ActivityKit. Its own `Codable` shape remains intentionally stable.
struct HerdPulseContentState: Codable, Hashable, Sendable {
    let workspaceCount: Int
    let paneCount: Int
    let workingCount: Int
    let attentionCount: Int
    let readyCount: Int
    let connection: HerdPulseConnection
    let phase: HerdPulsePhase
    let updatedAt: Int
}

enum HerdPulseConnection: String, Codable, Hashable, Sendable {
    case live
    case reconnecting
    case demo
    case offline
}

/// Phase priority is derived in `HerdPulseAggregate.phase` and is deterministic:
/// offline > attention > ready > working > resting.
enum HerdPulsePhase: String, Codable, Hashable, Sendable {
    case attention
    case ready
    case working
    case resting
    case offline
}
