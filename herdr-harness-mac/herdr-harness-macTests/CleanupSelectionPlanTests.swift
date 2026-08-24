import Testing
@testable import herdr_harness_mac

@Suite("Cleanup selection plan")
@MainActor
struct CleanupSelectionPlanTests {
    @Test("Selecting a workspace supersedes its child panes")
    func workspaceSupersedesChildren() throws {
        let original = try #require(CleanupRunController.demoReport().workspaces?.first)
        let workspace = closableCopy(of: original)
        var plan = CleanupSelectionPlan()

        plan.seed(with: [workspace])
        #expect(plan.paneIDs == Set(["w3:p1", "w3:p3"]))

        plan.toggleWorkspace(workspace)

        #expect(plan.workspaceIDs == Set([workspace.workspaceID]))
        #expect(plan.normalizedPaneIDs(in: [workspace]).isEmpty)
        #expect(plan.affectedPanes(in: [workspace]).count == workspace.panes.count)
        #expect(plan.activePiSessionCount(in: [workspace]) == 1)
    }

    @Test("Keeping a child open converts the workspace to sibling pane selections")
    func keepingPaneOpenReplacesWorkspaceSelection() throws {
        let original = try #require(CleanupRunController.demoReport().workspaces?.first)
        let workspace = closableCopy(of: original)
        let pane = try #require(workspace.panes.first(where: { $0.safeToClose }))
        var plan = CleanupSelectionPlan()

        plan.toggleWorkspace(workspace)
        plan.togglePane(pane, in: workspace)

        #expect(plan.workspaceIDs.isEmpty)
        #expect(plan.normalizedPaneIDs(in: [workspace]) == ["w3:p3"])
        #expect(plan.affectedPanes(in: [workspace]).map(\.paneID) == ["w3:p3"])
    }

    @Test("Dirty workspace keeps one anchor pane out of the default selection")
    func dirtyWorkspaceKeepsAnchorPane() throws {
        let original = try #require(CleanupRunController.demoReport().workspaces?.first)
        let clean = closableCopy(of: original)
        let dirty = CleanupWorkspaceReport(
            workspaceID: clean.workspaceID,
            label: clean.label,
            workspaceCloseRecommended: false,
            workspaceSafeToClose: false,
            workspaceBlockedBy: ["R6:git_dirty"],
            git: CleanupGitStatus(state: .dirty),
            panes: clean.panes,
            title: clean.title,
            workspaceReason: clean.workspaceReason,
            summary: clean.summary
        )
        var plan = CleanupSelectionPlan()

        plan.seed(with: [dirty])

        #expect(plan.paneIDs.count == dirty.panes.count - 1)
        #expect(Set(dirty.panes.map(\.paneID)).isSuperset(of: plan.paneIDs))
        let activePiPane = dirty.panes.first(where: { $0.piSession?.active == true })
        if let activePiPane {
            #expect(!plan.paneIDs.contains(activePiPane.paneID))
        }
    }

    private func closableCopy(of workspace: CleanupWorkspaceReport) -> CleanupWorkspaceReport {
        CleanupWorkspaceReport(
            workspaceID: workspace.workspaceID,
            label: workspace.label,
            workspaceCloseRecommended: true,
            workspaceSafeToClose: true,
            workspaceBlockedBy: [],
            git: workspace.git,
            panes: workspace.panes.filter(\.safeToClose),
            title: workspace.title,
            workspaceReason: workspace.workspaceReason,
            summary: workspace.summary
        )
    }
}
