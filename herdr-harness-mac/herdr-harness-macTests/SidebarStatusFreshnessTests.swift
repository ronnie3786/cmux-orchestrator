import Foundation
import Testing
@testable import herdr_harness_mac

/// The navigator caches its whole tree behind a fingerprint. Before this suite
/// that fingerprint carried `fleetRevision` and nothing status-shaped, so a
/// finished chat could keep drawing an amber "working" dot after a refresh the
/// model had judged uninteresting — while the HUD chips, which read the model
/// live, showed the same session as done.
@Suite("Sidebar status freshness")
@MainActor
struct SidebarStatusFreshnessTests {
    @Test("A pane's status change moves the sidebar cache key")
    func statusChangeChangesDigest() throws {
        let workspaces = DemoData.workspaces.map { $0.stamped(machineID: "m1") }
        let before = HerdrSidebarView.statusDigest(workspaces)

        var mutated = workspaces
        let workspaceIndex = try #require(mutated.firstIndex { !$0.panes.isEmpty })
        let pane = mutated[workspaceIndex].panes[0]
        #expect(pane.agentStatus == .working)
        mutated[workspaceIndex].panes[0] = Self.restatused(pane, as: .done)

        #expect(HerdrSidebarView.statusDigest(mutated) != before)
    }

    @Test("A workspace's rolled-up status change moves the cache key")
    func workspaceStatusChangeChangesDigest() throws {
        let workspaces = DemoData.workspaces.map { $0.stamped(machineID: "m1") }
        let before = HerdrSidebarView.statusDigest(workspaces)

        var mutated = workspaces
        let first = mutated[0]
        mutated[0] = HerdrWorkspace(
            workspaceID: first.workspaceID,
            number: first.number,
            label: first.label,
            focused: first.focused,
            paneCount: first.paneCount,
            tabCount: first.tabCount,
            activeTabID: first.activeTabID,
            agentStatus: first.agentStatus == .done ? .working : .done,
            tokens: first.tokens,
            worktree: first.worktree,
            tabs: first.tabs,
            panes: first.panes,
            agents: first.agents,
            layouts: first.layouts
        )
        .stamped(machineID: "m1")

        #expect(HerdrSidebarView.statusDigest(mutated) != before)
    }

    /// Revisions and transcripts churn constantly; only the drawn state should
    /// force the tree to be rebuilt.
    @Test("Churn that the rows never draw leaves the cache key alone")
    func unrelatedChangeKeepsDigest() throws {
        let workspaces = DemoData.workspaces.map { $0.stamped(machineID: "m1") }
        let before = HerdrSidebarView.statusDigest(workspaces)

        var mutated = workspaces
        let pane = mutated[0].panes[0]
        mutated[0].panes[0] = Self.restatused(pane, as: pane.agentStatus, revision: pane.revision + 7)

        #expect(HerdrSidebarView.statusDigest(mutated) == before)
    }

    private static func restatused(
        _ pane: HerdrPane,
        as status: AgentStatus,
        revision: Int? = nil
    ) -> HerdrPane {
        HerdrPane(
            paneID: pane.paneID,
            terminalID: pane.terminalID,
            workspaceID: pane.workspaceID,
            tabID: pane.tabID,
            focused: pane.focused,
            agentStatus: status,
            revision: revision ?? pane.revision,
            cwd: pane.cwd,
            foregroundCWD: pane.foregroundCWD,
            label: pane.label,
            title: pane.title,
            agent: pane.agent,
            displayAgent: pane.displayAgent,
            terminalTitle: pane.terminalTitle,
            terminalTitleStripped: pane.terminalTitleStripped,
            stateLabels: pane.stateLabels,
            tokens: pane.tokens,
            piSemantic: pane.piSemantic,
            firstSeenAt: pane.firstSeenAt,
            lastActivityAt: pane.lastActivityAt,
            workingSince: pane.workingSince
        )
        .stamped(machineID: pane.machineID)
    }
}
