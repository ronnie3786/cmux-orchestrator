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

        model.toggleSidebarSection("demo1|w1")
        #expect(model.collapsedSidebarWorkspaceIDs.contains("demo1|w1"))
        model.toggleSidebarSection("demo1|w1")
        #expect(!model.collapsedSidebarWorkspaceIDs.contains("demo1|w1"))

        model.openWorkspace(id: "demo1|w1")
        let selectedWorkspaceID = model.selectedWorkspaceID
        let selectedPaneID = model.selectedPaneID
        let workspacePath = model.workspacePath
        #expect(selectedWorkspaceID == "demo1|w1")
        #expect(selectedPaneID == model.workspace(id: "demo1|w1")?.sortedPanes.first?.id)
        #expect(workspacePath == [.workspace("demo1|w1")])

        model.openWorkspace(id: "does-not-exist")
        #expect(model.selectedWorkspaceID == selectedWorkspaceID)
        #expect(model.selectedPaneID == selectedPaneID)
        #expect(model.workspacePath == workspacePath)
    }

    @Test("Universal and custom-scheme links resolve pane IDs")
    func paneLinkParsing() throws {
        let cases: [(String, String?)] = [
            ("herdr://pane/w:p4", "w:p4"),
            ("herdr://open?pane=w:p9", "w:p9"),
            ("herdr://pane/w%3Ap4", "w:p4"),
            ("https://rocketbot.tail1db61d.ts.net:8461/open/pane/w:p4", "w:p4"),
            ("https://rocketbot.tail1db61d.ts.net:8461/open/pane/w%3Ap4", "w:p4"),
            ("https://rocketbot.tail1db61d.ts.net/open/pane?pane_id=w:p9", "w:p9"),
            ("https://rocketbot.tail1db61d.ts.net/OPEN/PANE/w:p4", "w:p4"),
            ("https://rocketbot.tail1db61d.ts.net/open", nil),
            ("https://rocketbot.tail1db61d.ts.net/open/workspace/w1", nil),
            ("https://rocketbot.tail1db61d.ts.net/api/v1/health", nil),
            ("mailto:someone@example.com", nil),
        ]
        for (raw, expected) in cases {
            let url = try #require(URL(string: raw))
            #expect(HerdrAppModel.paneID(from: url) == expected, "\(raw)")
        }
    }

    @MainActor
    @Test("Opening a universal link routes to the pane")
    func universalLinkRoutesToPane() throws {
        let model = HerdrAppModel(arguments: ["-HerdrDemoMode"])
        let pane = try #require(model.workspace(id: "demo1|w1")?.sortedPanes.first)
        let paneID = pane.paneID
        let encoded = try #require(
            paneID.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        )
        let url = try #require(
            URL(string: "https://rocketbot.tail1db61d.ts.net:8461/open/pane/\(encoded)")
        )

        model.open(url: url)

        #expect(model.selectedPaneID == pane.id)
        #expect(model.selectedTab == .workspaces)
    }

    @MainActor
    @Test("Connection failures escalate only after the reconnect grace period")
    func connectionFailureGracePeriod() {
        let model = HerdrAppModel(arguments: ["-HerdrDemoMode"])
        let onset = Date(timeIntervalSinceReferenceDate: 0)

        #expect(!model.noteConnectionFailure(machineID: "test-machine", now: onset))
        #expect(!model.noteConnectionFailure(machineID: "test-machine", now: onset.addingTimeInterval(5)))
        #expect(model.noteConnectionFailure(machineID: "test-machine", now: onset.addingTimeInterval(10.1)))

        model.useDemo()
        #expect(!model.noteConnectionFailure(machineID: "test-machine", now: onset.addingTimeInterval(100)))
    }

    @Test("Aggregate connection state follows machine state priority")
    func aggregateConnectionState() {
        #expect(HerdrAppModel.aggregateConnectionState(machineStates: [.failed], isDemoMode: true, hasMachines: true) == .demo)
        #expect(HerdrAppModel.aggregateConnectionState(machineStates: [], isDemoMode: false, hasMachines: false) == .disconnected)
        #expect(HerdrAppModel.aggregateConnectionState(machineStates: [.failed, .live], isDemoMode: false, hasMachines: true) == .live)
        #expect(HerdrAppModel.aggregateConnectionState(machineStates: [.failed, .connecting], isDemoMode: false, hasMachines: true) == .connecting)
        #expect(HerdrAppModel.aggregateConnectionState(machineStates: [.failed], isDemoMode: false, hasMachines: true) == .failed)
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
