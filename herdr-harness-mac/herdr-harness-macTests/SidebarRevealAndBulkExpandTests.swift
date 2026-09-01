import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Sidebar reveal and bulk expand", .serialized)
@MainActor
struct SidebarRevealAndBulkExpandTests {
    @Test("Revealing a pane expands its collapsed ancestors and publishes a request")
    func revealExpandsAncestorsAndPublishesRequest() throws {
        try withModel { model, pane in
            let workspace = try #require(model.workspace(containing: pane))
            model.collapsedSidebarMachineIDs = [pane.machineID]
            model.collapsedSidebarWorkspaceIDs = [workspace.id]
            model.collapsedSidebarTabIDs = [pane.scopedTabID]

            #expect(model.revealPaneInSidebar(id: pane.id))

            #expect(!model.collapsedSidebarMachineIDs.contains(pane.machineID))
            #expect(!model.collapsedSidebarWorkspaceIDs.contains(workspace.id))
            #expect(!model.collapsedSidebarTabIDs.contains(pane.scopedTabID))
            #expect(model.sidebarRevealPaneID == pane.id)
            #expect(model.sidebarRevealToken == 1)
        }
    }

    @Test("Revealing an unknown pane leaves the request token unchanged")
    func revealUnknownPaneLeavesTokenUnchanged() throws {
        try withModel { model, _ in
            #expect(!model.revealPaneInSidebar(id: "machine-a|missing:pane"))
            #expect(model.sidebarRevealToken == 0)
            #expect(model.sidebarRevealPaneID == nil)
        }
    }

    @Test("Revealing widens only a recency filter that excludes the pane")
    func revealWidensExcludedRecencyOnly() throws {
        try withModel { model, pane in
            model.sidebarRecency = .today
            #expect(model.revealPaneInSidebar(id: pane.id))
            #expect(model.sidebarRecency == .all)

            model.sidebarRecency = .all
            #expect(model.revealPaneInSidebar(id: pane.id))
            #expect(model.sidebarRecency == .all)
        }
    }

    @Test("Revealing retargets an incompatible machine scope")
    func revealRetargetsMachineScope() throws {
        try withModel { model, pane in
            model.machines = [
                HerdrMachine(id: "machine-a", name: "A", urlString: "http://a.example.com"),
                HerdrMachine(id: "machine-b", name: "B", urlString: "http://b.example.com"),
            ]
            model.setMachineScope(.machine("machine-b"))

            #expect(model.revealPaneInSidebar(id: pane.id))
            #expect(model.machineScope == .machine("machine-a"))
        }
    }

    @Test("Revealing the selection declines when no pane is selected")
    func revealSelectedPaneRequiresSelection() throws {
        try withModel { model, _ in
            model.selectedPaneID = nil
            #expect(!model.revealSelectedPaneInSidebar())
            #expect(model.sidebarRevealToken == 0)
        }
    }

    @Test("Bulk workspace expansion changes exactly its supplied ids")
    func setSidebarWorkspacesExpandedChangesOnlyScope() throws {
        try withModel { model, _ in
            model.collapsedSidebarWorkspaceIDs = ["w1", "w2", "outside"]

            model.setSidebarWorkspacesExpanded(true, ids: ["w1", "w2"])
            #expect(model.collapsedSidebarWorkspaceIDs == ["outside"])

            model.setSidebarWorkspacesExpanded(false, ids: ["w1", "w2"])
            #expect(model.collapsedSidebarWorkspaceIDs == ["w1", "w2", "outside"])
        }
    }

    @Test("Option workspace toggle applies the clicked direction to every row")
    func toggleSidebarSectionAppliesToAll() throws {
        try withModel { model, _ in
            let ids = ["w1", "w2", "w3"]
            let scope = Set(ids)
            model.collapsedSidebarWorkspaceIDs = ["w1"]

            model.toggleSidebarSection("w1", applyingToAll: ids)
            #expect(model.collapsedSidebarWorkspaceIDs.intersection(scope).isEmpty)

            model.toggleSidebarSection("w1", applyingToAll: ids)
            #expect(model.collapsedSidebarWorkspaceIDs.intersection(scope) == scope)
        }
    }

    @Test("Repeated option workspace toggles never leave a mixed scope")
    func repeatedWorkspaceToggleIsUniform() throws {
        try withModel { model, _ in
            let ids = ["w1", "w2"]
            let scope = Set(ids)
            model.collapsedSidebarWorkspaceIDs = Set(ids)

            model.toggleSidebarSection("w1", applyingToAll: ids)
            #expect(model.collapsedSidebarWorkspaceIDs.intersection(scope).isEmpty)

            model.toggleSidebarSection("w1", applyingToAll: ids)
            #expect(model.collapsedSidebarWorkspaceIDs.intersection(scope) == scope)
        }
    }

    @Test("Bulk tab expansion and option toggles change only a uniform scope")
    func setAndToggleSidebarTabsExpanded() throws {
        try withModel { model, _ in
            let ids = ["t1", "t2", "t3"]
            let scope = Set(ids)
            model.collapsedSidebarTabIDs = ["t1", "t2", "outside"]

            model.setSidebarTabsExpanded(true, ids: ["t1", "t2"])
            #expect(model.collapsedSidebarTabIDs == ["outside"])
            model.setSidebarTabsExpanded(false, ids: ["t1", "t2"])
            #expect(model.collapsedSidebarTabIDs == ["t1", "t2", "outside"])

            model.collapsedSidebarTabIDs = ["t1"]
            model.toggleSidebarTabSection("t1", applyingToAll: ids)
            #expect(model.collapsedSidebarTabIDs.intersection(scope).isEmpty)
            model.toggleSidebarTabSection("t1", applyingToAll: ids)
            #expect(model.collapsedSidebarTabIDs.intersection(scope) == scope)
        }
    }

    private func withModel(
        _ body: (HerdrAppModel, HerdrPane) throws -> Void
    ) throws {
        let suiteName = "SidebarRevealAndBulkExpandTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        let workspace = DemoData.workspaces[0].stamped(machineID: "machine-a")
        let pane = try #require(workspace.panes.last)
        model.machines = [HerdrMachine(id: "machine-a", name: "A", urlString: "http://a.example.com")]
        model.workspaces = [workspace]
        try body(model, pane)
    }
}
