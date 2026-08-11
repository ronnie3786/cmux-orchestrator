import SwiftUI

enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case live
    case demo
    case failed

    var title: String {
        switch self {
        case .disconnected: "Offline"
        case .connecting: "Connecting"
        case .live: "Live"
        case .demo: "Demo"
        case .failed: "Unavailable"
        }
    }

    var symbol: String {
        switch self {
        case .connecting: "arrow.trianglehead.2.clockwise.rotate.90"
        case .live: "bolt.horizontal.circle.fill"
        case .demo: "sparkles"
        case .failed: "exclamationmark.triangle.fill"
        case .disconnected: "wifi.slash"
        }
    }

    var color: Color {
        switch self {
        case .live: HerdrTheme.signal
        case .connecting: HerdrTheme.accent
        case .demo: HerdrTheme.mist
        case .failed: HerdrTheme.alert
        case .disconnected: HerdrTheme.muted
        }
    }
}
