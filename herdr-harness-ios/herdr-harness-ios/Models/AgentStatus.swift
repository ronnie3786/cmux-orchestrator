import SwiftUI

enum AgentStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case blocked
    case done
    case working
    case idle
    case unknown

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }

    var title: String {
        switch self {
        case .blocked: "Needs you"
        case .done: "Ready"
        case .working: "Working"
        case .idle: "Idle"
        case .unknown: "Shell"
        }
    }

    var compactTitle: String {
        switch self {
        case .blocked: "Blocked"
        case .done: "Done"
        case .working: "Working"
        case .idle: "Idle"
        case .unknown: "Unknown"
        }
    }

    var symbol: String {
        switch self {
        case .blocked: "hand.raised.fill"
        case .done: "checkmark.circle.fill"
        case .working: "waveform.path.ecg"
        case .idle: "circle.fill"
        case .unknown: "terminal.fill"
        }
    }

    var terminalGlyph: String {
        switch self {
        case .blocked, .done, .working: "●"
        case .idle: "○"
        case .unknown: "·"
        }
    }

    var color: Color {
        switch self {
        case .blocked: HerdrTheme.alert
        case .done: HerdrTheme.signal
        case .working: HerdrTheme.working
        case .idle: HerdrTheme.success
        case .unknown: HerdrTheme.muted
        }
    }

    var labelColor: Color {
        self == .unknown ? HerdrTheme.mist : color
    }

    var attentionRank: Int {
        switch self {
        case .blocked: 0
        case .done: 1
        case .working: 2
        case .idle: 3
        case .unknown: 4
        }
    }

    var needsAttention: Bool { self == .blocked || self == .done }
}
