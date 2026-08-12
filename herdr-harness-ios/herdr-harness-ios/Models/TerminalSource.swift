import SwiftUI

enum TerminalSource: Sendable {
    case connecting
    case stream
    case snapshot
    case disconnected

    var label: String {
        switch self {
        case .connecting: "connecting"
        case .stream: "live"
        case .snapshot: "watching"
        case .disconnected: "offline"
        }
    }

    var symbol: String {
        switch self {
        case .connecting: "ellipsis"
        case .stream: "circle.fill"
        case .snapshot: "arrow.trianglehead.2.clockwise.rotate.90"
        case .disconnected: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .connecting: HerdrTheme.working
        case .stream: HerdrTheme.success
        case .snapshot: HerdrTheme.accent
        case .disconnected: HerdrTheme.alert
        }
    }
}
