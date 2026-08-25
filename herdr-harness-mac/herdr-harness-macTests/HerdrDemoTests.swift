import Testing
@testable import herdr_harness_mac

@Suite("Demo command deck", .serialized)
@MainActor
struct HerdrDemoTests {
    @Test("Fixture hierarchy is internally consistent")
    func fixtureHierarchyIsConsistent() {
        #expect(DemoData.workspaces.map(\.id) == ["w1", "w2", "w3"])

        for workspace in DemoData.workspaces {
            #expect(workspace.paneCount == workspace.panes.count)
            #expect(workspace.tabCount == workspace.tabs.count)
            #expect(workspace.panes.allSatisfy { $0.workspaceID == workspace.id })

            let tabIDs = Set(workspace.tabs.map(\.id))
            #expect(workspace.panes.allSatisfy { tabIDs.contains($0.scopedTabID) })

            let paneIDs = Set(workspace.panes.map(\.id))
            for layout in workspace.layouts {
                #expect(layout.workspaceID == workspace.id)
                #expect(layout.panes.allSatisfy { paneIDs.contains($0.id) })
            }
        }
        for workspace in DemoData.workspacesForWorkMBP {
            #expect(workspace.paneCount == workspace.panes.count)
            #expect(workspace.tabCount == workspace.tabs.count)
            #expect(workspace.panes.allSatisfy { $0.workspaceID == workspace.id })
        }
    }

    @Test("Demo model promotes blocked and completed sessions")
    func attentionDeckOrdering() {
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"])

        #expect(model.connectionState == .demo)
        #expect(model.visibleWorkspaces.map(\.id) == ["demo1|w1", "demo2|w1", "demo1|w2", "demo2|w2", "demo1|w3"])
        #expect(model.attentionPanes.map(\.id) == ["demo1|w1:p2", "demo1|w2:p1", "demo2|w2:p1"])
        #expect(model.unreadAlertCount == 2)
        #expect(model.workingCount == 3)
        #expect(model.paneCount == 9)
    }

    @Test("Search and filters inspect workspace, pane, and activity metadata")
    func searchAndFilters() {
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"])

        model.searchText = "pagination"
        #expect(model.visibleWorkspaces.map(\.id) == ["demo1|w2"])

        model.searchText = ""
        model.filter = .active
        #expect(model.visibleWorkspaces.map(\.id) == ["demo1|w1", "demo2|w1", "demo1|w2"])

        model.filter = .attention
        #expect(model.visibleWorkspaces.map(\.id) == ["demo1|w1", "demo1|w2", "demo2|w2"])
    }

    @Test("Demo terminal and prompt actions behave without network access")
    func terminalAndPromptActions() async throws {
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"])
        let pane = try #require(model.pane(id: "demo1|w1:p2"))

        let output = try await model.fetchOutput(for: pane)
        #expect(output.paneID == pane.paneID)
        #expect(output.text.contains("Waiting for your response"))
        #expect(output.revision == pane.revision)

        #expect(await model.sendPrompt("  ", to: pane) == false)
        #expect(await model.sendPrompt("Yes, proceed", to: pane))
        #expect(model.toastMessage == "Sent to Claude")
    }

    @Test("Demo end-pi-session action behaves without network access")
    func endsPiSessionInDemoMode() async throws {
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"])
        let pane = try #require(model.pane(id: "demo1|w1:p2"))

        await model.endPiSession(in: pane)

        #expect(model.toastMessage == "ended the pi session")
    }

    @Test("Demo adds a shell to a tab without network access")
    func addsShellToTabInDemoMode() async throws {
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"])
        let workspace = try #require(model.workspaces.first)
        let tab = try #require(workspace.tabs.first)

        await model.addPane(toTab: tab, in: workspace)

        #expect(model.toastMessage == "added a shell")
    }

    @Test("Demo starts pi in a tab without network access")
    func startsPiInTabInDemoMode() async throws {
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"])
        let workspace = try #require(model.workspaces.first)
        let tab = try #require(workspace.tabs.first)

        await model.addPane(toTab: tab, in: workspace, running: "pi")

        #expect(model.toastMessage == "started a new pi chat")
    }

    @Test("Reading one demo alert preserves the rest of the feed")
    func marksSingleAlertRead() async throws {
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"])
        let alert = try #require(model.alerts.first)

        await model.markAlertRead(alert)

        #expect(model.alerts.count == DemoData.alerts.count)
        #expect(model.alerts.first(where: { $0.id == alert.id })?.isRead == true)
        #expect(model.unreadAlertCount == 1)
    }

    @Test("Opening a demo pane clears only its alerts")
    func openingPaneClearsItsAlerts() throws {
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"])
        #expect(model.unreadAlertCount == 2)

        model.openPane(id: "demo1|w1:p2")

        #expect(model.alerts.first(where: { $0.rawID == "demo-blocked" })?.isRead == true)
        #expect(model.alerts.first(where: { $0.rawID == "demo-done" })?.isRead == false)
        #expect(model.unreadAlertCount == 1)
    }
}
