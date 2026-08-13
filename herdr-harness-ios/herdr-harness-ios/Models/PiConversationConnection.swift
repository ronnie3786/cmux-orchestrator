import Foundation

enum PiConversationConnection: Equatable, Sendable {
    case loading
    case connected
    case bridgeOffline
    case reconnecting(attempt: Int)
    case unavailable

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}
