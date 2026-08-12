struct AgentStatusHapticTracker: Equatable, Sendable {
    private var previousStatuses: [String: AgentStatus]?
    private var isArmed = false
    private var isAwaitingForegroundRefresh = false

    mutating func reset(to statuses: [String: AgentStatus]) {
        previousStatuses = statuses
    }

    mutating func setSceneActive(
        _ isActive: Bool,
        isDemoMode: Bool,
        statuses: [String: AgentStatus]
    ) {
        isArmed = isActive && isDemoMode
        isAwaitingForegroundRefresh = isActive && !isDemoMode
        reset(to: statuses)
    }

    /// Re-arms after the first server refresh on foreground entry. Ordinary
    /// refreshes intentionally do nothing so SwiftUI batching cannot erase a
    /// real status transition before it is observed.
    mutating func recordRefresh(statuses: [String: AgentStatus]) {
        guard isAwaitingForegroundRefresh else { return }
        reset(to: statuses)
        isArmed = true
        isAwaitingForegroundRefresh = false
    }

    mutating func observe(_ statuses: [String: AgentStatus]) -> HerdrHaptic? {
        defer { previousStatuses = statuses }
        guard isArmed, let previousStatuses else { return nil }

        var completed = false
        for (paneID, status) in statuses {
            guard let previous = previousStatuses[paneID], previous != status else { continue }
            if status == .blocked { return .attention }
            if status == .done { completed = true }
        }
        return completed ? .completed : nil
    }

    static func snapshot(_ workspaces: [HerdrWorkspace]) -> [String: AgentStatus] {
        workspaces.reduce(into: [:]) { statuses, workspace in
            for pane in workspace.panes {
                statuses[pane.id] = pane.agentStatus
            }
        }
    }
}
