import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Herdr domain models")
struct HerdrModelTests {
    @Test("Agent states rank attention before background activity")
    func agentStatusAttentionOrdering() throws {
        let decoded = try JSONDecoder().decode(
            [AgentStatus].self,
            from: Data("[\"idle\",\"working\",\"done\",\"blocked\",\"new-agent-state\"]".utf8)
        )
        let sorted = decoded.sorted { $0.attentionRank < $1.attentionRank }

        #expect(sorted == [.blocked, .done, .working, .idle, .unknown])
        #expect(AgentStatus.blocked.needsAttention)
        #expect(AgentStatus.done.needsAttention)
        #expect(!AgentStatus.working.needsAttention)
    }

    @Test("Workspace pane ordering is deterministic within equal priorities")
    func workspaceSortsPanesByAttentionTabAndIdentity() {
        let panes = [
            pane(id: "w:p9", tabID: "w:t2", status: .idle, revision: 1),
            pane(id: "w:p4", tabID: "w:t1", status: .blocked, revision: 2),
            pane(id: "w:p2", tabID: "w:t1", status: .blocked, revision: 3),
            pane(id: "w:p1", tabID: "w:t2", status: .done, revision: 4),
        ]
        let workspace = HerdrWorkspace(
            workspaceID: "w",
            number: 1,
            label: "Ordering",
            focused: false,
            paneCount: panes.count,
            tabCount: 2,
            activeTabID: "w:t1",
            agentStatus: .blocked,
            panes: panes
        )

        #expect(workspace.sortedPanes.map(\.id) == ["w:p2", "w:p4", "w:p1", "w:p9"])
        #expect(workspace.attentionCount == 3)
        #expect(workspace.workingCount == 0)
    }

    @Test("Server configuration normalizes URL and credential input")
    func serverConfigurationNormalizesInput() throws {
        let configuration = try #require(
            ServerConfiguration(
                urlString: "  https://herdr.work-machine.example:9092/api///  ",
                token: "  secret-token \n"
            )
        )

        #expect(configuration.baseURL.absoluteString == "https://herdr.work-machine.example:9092/api")
        #expect(configuration.token == "secret-token")
    }

    @Test(
        "Server configuration rejects unsafe or incomplete endpoints",
        arguments: [
            "",
            "herdr.work-machine.example",
            "ftp://herdr.work-machine.example",
            "http:///missing-host",
        ]
    )
    func serverConfigurationRejectsInvalidURL(_ value: String) {
        #expect(ServerConfiguration(urlString: value, token: "token") == nil)
    }

    @MainActor
    @Test("Sidebar navigation persists collapsed sections and opens workspaces")
    func sidebarNavigation() {
        UserDefaults.standard.removeObject(forKey: "herdr.sidebar.collapsedWorkspaces")
        let model = HerdrAppModel(arguments: ["-HerdrDemoMode"])

        model.toggleSidebarSection("w1")
        #expect(model.collapsedSidebarWorkspaceIDs.contains("w1"))
        model.toggleSidebarSection("w1")
        #expect(!model.collapsedSidebarWorkspaceIDs.contains("w1"))

        model.openWorkspace(id: "w1")
        let selectedWorkspaceID = model.selectedWorkspaceID
        let selectedPaneID = model.selectedPaneID
        let workspacePath = model.workspacePath
        #expect(selectedWorkspaceID == "w1")
        #expect(selectedPaneID == model.workspace(id: "w1")?.sortedPanes.first?.id)
        #expect(workspacePath == [.workspace("w1")])

        model.openWorkspace(id: "does-not-exist")
        #expect(model.selectedWorkspaceID == selectedWorkspaceID)
        #expect(model.selectedPaneID == selectedPaneID)
        #expect(model.workspacePath == workspacePath)
    }

    private func pane(
        id: String,
        tabID: String,
        status: AgentStatus,
        revision: Int
    ) -> HerdrPane {
        HerdrPane(
            paneID: id,
            terminalID: id,
            workspaceID: "w",
            tabID: tabID,
            focused: false,
            agentStatus: status,
            revision: revision,
            cwd: nil,
            foregroundCWD: nil,
            label: nil,
            title: nil,
            agent: nil,
            displayAgent: nil,
            terminalTitle: nil,
            terminalTitleStripped: nil
        )
    }
}
