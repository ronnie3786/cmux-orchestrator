import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Shell navigation history", .serialized)
@MainActor
struct ShellNavigationHistoryTests {
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

    @Test("Fleet is a standalone destination outside the detail picker")
    func fleetIsExcludedFromDetailPickerAndRecordsNavigation() throws {
        #expect(!HerdrDetailScope.pickerCases.contains(.fleet))
        #expect(HerdrDetailScope.pickerSelection(for: .fleet) == nil)
        #expect(HerdrDetailScope.pickerSelection(for: .attention) == .attention)

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
