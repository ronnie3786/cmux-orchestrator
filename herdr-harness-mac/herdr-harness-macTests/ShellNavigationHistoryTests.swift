import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Shell navigation history", .serialized)
@MainActor
struct ShellNavigationHistoryTests {
    @Test("Git only earns a picker segment when the pane on screen has a repo")
    func gitSegmentFollowsRepoAvailability() {
        let withGit = HerdrDetailScope.pickerCases(includingGit: true)
        let withoutGit = HerdrDetailScope.pickerCases(includingGit: false)

        #expect(withGit.contains(.git))
        #expect(!withoutGit.contains(.git))
        // Right of chat, as asked: Session is the chat-bubble segment.
        #expect(withGit.firstIndex(of: .git) == 1)
        #expect(withGit.first == .session)
        #expect(withoutGit == withGit.filter { $0 != .git })
    }

    @Test("Only the publishing pane may retract the mode the toolbar reads")
    func paneModeOwnershipSurvivesAPaneSwitch() {
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"])
        model.notePaneDetailMode(.git, gitIsAvailable: true, for: "m1|a")
        // Switching panes mounts the replacement before the outgoing view
        // disappears, so the stale clear must be ignored.
        model.notePaneDetailMode(.chat, gitIsAvailable: false, for: "m1|b")
        model.clearPaneDetailMode(for: "m1|a")

        #expect(model.currentPaneDetailMode == .chat)
        #expect(!model.currentPaneGitIsAvailable)

        model.clearPaneDetailMode(for: "m1|b")
        #expect(model.currentPaneDetailMode == nil)
    }

    @Test("Git is a pane sub-mode, so it never resolves to a window destination")
    func gitScopeResolvesToTheSession() {
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"])
        let shell = HerdrShellState()
        shell.detailScope = .git

        // With no pane selected it degrades exactly like `.session` does rather
        // than rendering an empty Git surface.
        #expect(shell.resolvedScope(for: model) != .git)
    }

    @Test("Opening a pane, a workspace, and Active Work records three visits")
    func openingDestinationsRecordsTrail() throws {
        try withModel { model, firstPane, _, firstWorkspace, _ in
            let shell = HerdrShellState()

            shell.openPane(id: firstPane.id, model: model)
            shell.showWorkspace(id: firstWorkspace.id, model: model)
            shell.show(.activeWork, model: model)

            #expect(shell.canGoBack)
            #expect(shell.goBack(model: model))
            #expect(shell.detailScope == .workspace)
            #expect(shell.goBack(model: model))
            #expect(shell.detailScope == .session)
            #expect(model.selectedPaneID == firstPane.id)
        }
    }

    @Test("Re-opening the pane already on screen records nothing")
    func reopeningCurrentPaneIsDeduplicated() throws {
        try withModel { model, firstPane, _, _, _ in
            let shell = HerdrShellState()

            shell.openPane(id: firstPane.id, model: model)
            shell.openPane(id: firstPane.id, model: model)

            #expect(!shell.canGoBack)
        }
    }

    @Test("A scope change with no selected pane records the resolved destination")
    func panelessSessionRecordsResolvedDestination() throws {
        try withModel { model, _, _, firstWorkspace, _ in
            let shell = HerdrShellState()
            model.selectedWorkspaceID = firstWorkspace.id
            model.selectedPaneID = nil

            shell.show(.session, model: model)

            #expect(shell.history.current == .workspace(firstWorkspace.id))
            #expect(shell.history.current != nil)
        }
    }

    @Test("Fleet is a detail-picker segment and records navigation")
    func fleetIsADetailPickerSegmentAndRecordsNavigation() throws {
        #expect(HerdrDetailScope.pickerCases.contains(.fleet))
        #expect(HerdrDetailScope.pickerSelection(for: .fleet) == .fleet)
        #expect(HerdrDetailScope.pickerSelection(for: .attention) == .attention)
        // Every destination is a segment today, so the proxy is the identity —
        // pin that rather than let a dropped case pass unnoticed.
        #expect(HerdrDetailScope.pickerCases == HerdrDetailScope.allCases)

        try withModel { model, firstPane, _, _, _ in
            let shell = HerdrShellState()
            shell.openPane(id: firstPane.id, model: model)
            shell.show(.fleet, model: model)

            #expect(shell.detailScope == .fleet)
            #expect(shell.currentDestination(for: model) == .fleet)
            #expect(shell.history.current == .fleet)
            #expect(shell.goBack(model: model))
            #expect(shell.detailScope == .session)
            #expect(model.selectedPaneID == firstPane.id)
        }
    }

    @Test("Back restores the pane and the detail scope together")
    func backRestoresPaneAndScope() throws {
        try withModel { model, firstPane, _, firstWorkspace, _ in
            let shell = HerdrShellState()
            shell.openPane(id: firstPane.id, model: model)
            shell.showWorkspace(id: firstWorkspace.id, model: model)

            #expect(shell.goBack(model: model))
            #expect(shell.detailScope == .session)
            #expect(model.selectedPaneID == firstPane.id)
        }
    }

    @Test("Back does not record a new visit")
    func backLeavesForwardReachable() throws {
        try withModel { model, firstPane, secondPane, _, _ in
            let shell = HerdrShellState()
            shell.openPane(id: firstPane.id, model: model)
            shell.openPane(id: secondPane.id, model: model)

            #expect(shell.goBack(model: model))
            #expect(shell.canGoForward)
        }
    }

    @Test("A pane that leaves the fleet is pruned and greys the Back button")
    func pruneRemovesDeadPaneFromBackStack() throws {
        try withModel { model, firstPane, _, _, _ in
            let shell = HerdrShellState()
            shell.openPane(id: firstPane.id, model: model)
            shell.show(.activeWork, model: model)
            model.workspaces = []

            shell.pruneHistory(for: model)

            #expect(!shell.canGoBack)
        }
    }

    @Test("Back never routes to a dead pane")
    func backSkipsDeadPane() throws {
        try withModel { model, firstPane, secondPane, firstWorkspace, _ in
            let shell = HerdrShellState()
            shell.openPane(id: firstPane.id, model: model)
            shell.openPane(id: secondPane.id, model: model)
            model.workspaces.removeAll { $0.id == firstWorkspace.id }

            #expect(!shell.goBack(model: model))
            #expect(model.selectedPaneID != firstPane.id)
            #expect(model.selectedPaneID == secondPane.id)
        }
    }

    @Test("Forward stack is cleared by a fresh navigation from the shell funnels")
    func freshNavigationClearsForwardStack() throws {
        try withModel { model, firstPane, secondPane, _, _ in
            let shell = HerdrShellState()
            shell.openPane(id: firstPane.id, model: model)
            shell.openPane(id: secondPane.id, model: model)
            #expect(shell.goBack(model: model))

            shell.show(.attention, model: model)

            #expect(!shell.canGoForward)
        }
    }

    private func withModel(
        _ body: (HerdrAppModel, HerdrPane, HerdrPane, HerdrWorkspace, HerdrWorkspace) throws -> Void
    ) throws {
        let suiteName = "ShellNavigationHistoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        let firstWorkspace = DemoData.workspaces[0].stamped(machineID: "machine-a")
        let secondWorkspace = DemoData.workspaces[1].stamped(machineID: "machine-a")
        let firstPane = try #require(firstWorkspace.panes.first)
        let secondPane = try #require(secondWorkspace.panes.first)
        model.machines = [HerdrMachine(id: "machine-a", name: "A", urlString: "http://a.example.com")]
        model.workspaces = [firstWorkspace, secondWorkspace]
        try body(model, firstPane, secondPane, firstWorkspace, secondWorkspace)
    }
}
