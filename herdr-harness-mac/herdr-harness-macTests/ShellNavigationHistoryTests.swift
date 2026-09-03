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
        try withModel { model, shell, firstPane, _, firstWorkspace, _ in

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
        try withModel { model, shell, firstPane, _, _, _ in

            shell.openPane(id: firstPane.id, model: model)
            shell.openPane(id: firstPane.id, model: model)

            #expect(!shell.canGoBack)
        }
    }

    @Test("A scope change with no selected pane records the resolved destination")
    func panelessSessionRecordsResolvedDestination() throws {
        try withModel { model, shell, _, _, firstWorkspace, _ in
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

        try withModel { model, shell, firstPane, _, _, _ in
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
        try withModel { model, shell, firstPane, _, firstWorkspace, _ in
            shell.openPane(id: firstPane.id, model: model)
            shell.showWorkspace(id: firstWorkspace.id, model: model)

            #expect(shell.goBack(model: model))
            #expect(shell.detailScope == .session)
            #expect(model.selectedPaneID == firstPane.id)
        }
    }

    @Test("Back does not record a new visit")
    func backLeavesForwardReachable() throws {
        try withModel { model, shell, firstPane, secondPane, _, _ in
            shell.openPane(id: firstPane.id, model: model)
            shell.openPane(id: secondPane.id, model: model)

            #expect(shell.goBack(model: model))
            #expect(shell.canGoForward)
        }
    }

    @Test("A pane that leaves the fleet is pruned and greys the Back button")
    func pruneRemovesDeadPaneFromBackStack() throws {
        try withModel { model, shell, firstPane, _, firstWorkspace, _ in
            shell.openPane(id: firstPane.id, model: model)
            shell.show(.activeWork, model: model)
            // Removing only the dead pane's workspace (not the whole fleet) keeps
            // model.workspaces non-empty, so this exercises genuine pruning
            // rather than pruneHistory's new pre-load early-return: an empty
            // model.workspaces now means "the fleet hasn't loaded yet".
            model.workspaces.removeAll { $0.id == firstWorkspace.id }

            shell.pruneHistory(for: model)

            #expect(!shell.canGoBack)
        }
    }

    @Test("A restored history survives pruneHistory until the fleet has loaded")
    func restoredHistorySurvivesPruneBeforeFleetLoads() throws {
        let suiteName = "ShellNavigationHistoryTests.restore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let snapshot = NavigationHistorySnapshot(
            version: NavigationHistorySnapshot.currentVersion,
            backward: [HerdrDestinationRecord(.pane("machine-a|w1:p1"))!],
            current: HerdrDestinationRecord(.activeWork),
            forward: []
        )
        NavigationHistoryPersistenceStore(userDefaults: defaults).save(snapshot)

        let shell = HerdrShellState(userDefaults: defaults)
        #expect(shell.canGoBack)
        #expect(shell.history.backward == [.pane("machine-a|w1:p1")])

        // Fresh model, no workspaces loaded yet: the pre-load state.
        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        #expect(model.workspaces.isEmpty)

        shell.pruneHistory(for: model)

        #expect(shell.canGoBack)
        #expect(shell.history.backward == [.pane("machine-a|w1:p1")])
    }

    @Test("Back never routes to a dead pane")
    func backSkipsDeadPane() throws {
        try withModel { model, shell, firstPane, secondPane, firstWorkspace, _ in
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
        try withModel { model, shell, firstPane, secondPane, _, _ in
            shell.openPane(id: firstPane.id, model: model)
            shell.openPane(id: secondPane.id, model: model)
            #expect(shell.goBack(model: model))

            shell.show(.attention, model: model)

            #expect(!shell.canGoForward)
        }
    }

    private func withModel(
        _ body: (HerdrAppModel, HerdrShellState, HerdrPane, HerdrPane, HerdrWorkspace, HerdrWorkspace) throws -> Void
    ) throws {
        let suiteName = "ShellNavigationHistoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        let shell = HerdrShellState(userDefaults: defaults)
        let firstWorkspace = DemoData.workspaces[0].stamped(machineID: "machine-a")
        let secondWorkspace = DemoData.workspaces[1].stamped(machineID: "machine-a")
        let firstPane = try #require(firstWorkspace.panes.first)
        let secondPane = try #require(secondWorkspace.panes.first)
        model.machines = [HerdrMachine(id: "machine-a", name: "A", urlString: "http://a.example.com")]
        model.workspaces = [firstWorkspace, secondWorkspace]
        try body(model, shell, firstPane, secondPane, firstWorkspace, secondWorkspace)
    }
}
