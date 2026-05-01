import Foundation

enum DiscoveredHarnessServerSource: String, Equatable, Sendable {
    case tailscale
    case lan
}

struct DiscoveredHarnessServer: Equatable, Identifiable, Sendable {
    var name: String
    var urlString: String
    var source: DiscoveredHarnessServerSource

    var id: String {
        urlString
    }
}

struct RefreshPayload: Equatable, Sendable {
    var status: HarnessStatus
    var log: [LogEntry]
}
