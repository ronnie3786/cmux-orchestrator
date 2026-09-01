import SwiftUI

enum HerdPulseTheme {
    static let ink = Color(red: 0.094, green: 0.094, blue: 0.145)
    static let graphite = Color(red: 0.118, green: 0.118, blue: 0.180)
    static let elevated = Color(red: 0.192, green: 0.196, blue: 0.267)
    static let mist = Color(red: 0.651, green: 0.678, blue: 0.784)
    static let text = Color(red: 0.804, green: 0.839, blue: 0.957)
    static let accent = Color(red: 0.537, green: 0.706, blue: 0.980)
    static let signal = Color(red: 0.580, green: 0.886, blue: 0.835)
    static let working = Color(red: 0.976, green: 0.886, blue: 0.686)
    static let alert = Color(red: 0.953, green: 0.545, blue: 0.659)

    static func color(for phase: HerdPulsePhase) -> Color {
        switch phase {
        case .attention: alert
        case .ready: signal
        case .working: working
        case .resting: accent
        case .offline: mist
        }
    }

    static func color(for state: HerdPulseSessionState) -> Color {
        switch state {
        case .blocked: alert
        case .done: signal
        case .working: working
        }
    }
}
