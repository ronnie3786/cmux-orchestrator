import Foundation

struct HerdPulseAggregate: Equatable, Sendable {
    let workspaceCount: Int
    let paneCount: Int
    let workingCount: Int
    let attentionCount: Int
    let readyCount: Int
    let connection: HerdPulseConnection
    let sessions: [HerdPulseAttributes.ContentState.Session]
    let sessionOverflow: Int
    let revealSessionTitles: Bool

    init(workspaces: [HerdrWorkspace], connectionState: ConnectionState) {
        self.init(
            workspaces: workspaces,
            alerts: [],
            pendingReadPaneIDs: [],
            revealTitles: false,
            connectionState: connectionState
        )
    }

    init(
        workspaces: [HerdrWorkspace],
        alerts: [HerdrAlert],
        pendingReadPaneIDs: Set<String>,
        revealTitles: Bool,
        connectionState: ConnectionState
    ) {
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
        let projection = HerdPulseSessions.sessions(
            panes: panes,
            alerts: alerts,
            pendingReadPaneIDs: pendingReadPaneIDs,
            revealTitles: revealTitles
        )
        sessions = projection.sessions
        sessionOverflow = projection.overflow
        revealSessionTitles = revealTitles
    }

    var phase: HerdPulsePhase {
        if connection == .offline { return .offline }
        if attentionCount > 0 { return .attention }
        if readyCount > 0 { return .ready }
        if workingCount > 0 { return .working }
        return .resting
    }

    func contentState(at date: Date = .now) -> HerdPulseAttributes.ContentState {
        HerdPulseAttributes.ContentState(
            workspaceCount: workspaceCount,
            paneCount: paneCount,
            workingCount: workingCount,
            attentionCount: attentionCount,
            readyCount: readyCount,
            connection: connection,
            phase: phase,
            updatedAt: Int(date.timeIntervalSince1970),
            sessions: sessions,
            sessionOverflow: sessionOverflow
        )
    }
}
