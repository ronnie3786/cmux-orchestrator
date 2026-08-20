import Foundation

struct HerdPulseAggregate: Equatable, Sendable {
    let workspaceCount: Int
    let paneCount: Int
    let workingCount: Int
    let attentionCount: Int
    let readyCount: Int
    let connection: HerdPulseConnection

    init(workspaces: [HerdrWorkspace], connectionState: ConnectionState) {
        let panes = workspaces.flatMap(\.panes)
        workspaceCount = workspaces.count
        paneCount = panes.count
        workingCount = panes.count(where: { $0.agentStatus == .working })
        attentionCount = panes.count(where: { $0.agentStatus == .blocked })
        readyCount = panes.count(where: { $0.agentStatus == .done })
        connection = switch connectionState {
        case .live: .live
        case .connecting: .reconnecting
        case .demo: .demo
        case .disconnected, .failed: .offline
        }
    }

    var phase: HerdPulsePhase {
        if connection == .offline { return .offline }
        if attentionCount > 0 { return .attention }
        if readyCount > 0 { return .ready }
        if workingCount > 0 { return .working }
        return .resting
    }

    func contentState(at date: Date = .now) -> HerdPulseContentState {
        HerdPulseContentState(
            workspaceCount: workspaceCount,
            paneCount: paneCount,
            workingCount: workingCount,
            attentionCount: attentionCount,
            readyCount: readyCount,
            connection: connection,
            phase: phase,
            updatedAt: Int(date.timeIntervalSince1970)
        )
    }
}
