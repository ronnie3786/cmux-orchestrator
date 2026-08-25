import Foundation

/// One routable pane plus the human-readable context used by the global
/// command palette. Keeping only value data here makes fuzzy matching safe to
/// run and test without reaching into observable application state.
struct CommandPaletteEntry: Identifiable, Equatable, Sendable {
    let paneID: String
    let title: String
    let agentName: String
    let workspaceName: String
    let workspacePath: String
    let tabName: String
    let machineName: String
    let status: AgentStatus
    let order: Int

    var id: String { paneID }

    var contextLine: String {
        [agentName, workspaceName, tabName]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var accessibilitySummary: String {
        [title, agentName, workspaceName, tabName, machineName, status.title]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}
