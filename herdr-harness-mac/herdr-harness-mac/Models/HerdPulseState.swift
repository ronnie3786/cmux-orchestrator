import Foundation

/// The only state Herdr exposes outside its own window. Keep this payload
/// aggregate-only: on Mac the menu bar is visible in screen shares, recordings,
/// and screenshots, exactly like the iOS lock screen it replaces.
///
/// Extracted from `HerdrPulseShared/HerdPulseAttributes.swift` without
/// ActivityKit — the `Codable` shape (property names, order, and the eight
/// encoded keys) is unchanged so the privacy assertion still pins it.
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
