import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Machine management", .serialized)
@MainActor
struct MachinesManagementTests {
    @Test("Adding a valid machine persists its configuration and token")
    func addMachinePersists() throws {
        try withCleanMachineDefaults { model, defaults in
            let generation = model.connectionGeneration
            #expect(model.addMachine(name: "Rocketbot", urlString: "https://rocketbot.example.com", token: "token-a"))
            let machine = try #require(model.machines.first)
            let persisted = try #require(defaults.data(forKey: "herdr.machines"))
            #expect(try JSONDecoder().decode([HerdrMachine].self, from: persisted) == [machine])
            #expect(KeychainStore.value(for: "api-token.\(machine.id)") == "token-a")
            #expect(model.connectionGeneration == generation + 1)
            KeychainStore.removeValue(for: "api-token.\(machine.id)")
        }
    }

    @Test("Adding an invalid machine leaves state unchanged")
    func addMachineRejectsInvalidURL() throws {
        try withCleanMachineDefaults { model, _ in
            #expect(!model.addMachine(name: "Broken", urlString: "not a url", token: "token"))
            #expect(model.machines.isEmpty)
            #expect(model.errorMessage != nil)
        }
    }

    @Test("Editing a machine preserves its scoped workspace UI state")
    func updateMachinePreservesScopedSlices() throws {
        try withCleanMachineDefaults { model, _ in
            let machine = HerdrMachine(id: "machine-a", name: "Before", urlString: "https://before.example.com")
            let workspace = DemoData.workspaces[0].stamped(machineID: machine.id)
            let alert = DemoData.alerts[0].stamped(machineID: machine.id)
            model.machines = [machine]
            model.workspaces = [workspace]
            model.alerts = [alert]
            model.starredChatIDs = [workspace.panes[0].id]
            model.collapsedSidebarWorkspaceIDs = [workspace.id]
            model.collapsedSidebarMachineIDs = [machine.id]

            #expect(model.updateMachine(id: machine.id, name: "After", urlString: "https://after.example.com", token: "token-b"))
            #expect(model.machines[0].name == "After")
            #expect(model.machines[0].urlString == "https://after.example.com")
            #expect(model.workspaces == [workspace])
            #expect(model.alerts == [alert])
            #expect(model.starredChatIDs == [workspace.panes[0].id])
            #expect(model.collapsedSidebarWorkspaceIDs == [workspace.id])
            #expect(model.collapsedSidebarMachineIDs == [machine.id])
            KeychainStore.removeValue(for: "api-token.\(machine.id)")
        }
    }

    @Test("Removing the scoped machine resets scope and prunes machine collapse state")
    func removeMachineResetsScope() throws {
        try withCleanMachineDefaults { model, _ in
            let machine = HerdrMachine(id: "machine-a", name: "A", urlString: "https://a.example.com")
            model.machines = [machine]
            model.machineScope = .machine(machine.id)
            model.collapsedSidebarMachineIDs = [machine.id]

            model.removeMachine(id: machine.id)

            #expect(model.machineScope == .all)
            #expect(!model.collapsedSidebarMachineIDs.contains(machine.id))
        }
    }

    @Test("Reordering machines persists display and primary order")
    func reorderMachinesPersists() throws {
        try withCleanMachineDefaults { model, defaults in
            let first = HerdrMachine(id: "first", name: "First", urlString: "https://first.example.com")
            let second = HerdrMachine(id: "second", name: "Second", urlString: "https://second.example.com")
            model.machines = [first, second]
            model.reorderMachines(from: IndexSet(integer: 1), to: 0)

            #expect(model.machines.map(\.id) == ["second", "first"])
            let data = try #require(defaults.data(forKey: "herdr.machines"))
            #expect(try JSONDecoder().decode([HerdrMachine].self, from: data).map(\.id) == ["second", "first"])
            #expect(model.machines.first?.id == "second")
        }
    }

    private func withCleanMachineDefaults(
        _ body: (HerdrAppModel, UserDefaults) throws -> Void
    ) throws {
        let defaults = UserDefaults.standard
        let keys = [
            "herdr.machines", "herdr.serverURL", "herdr.demoMode", "herdr.completedSetup",
            "herdr.machineScope", "herdr.sidebar.starredChats", "herdr.sidebar.collapsedWorkspaces",
            "herdr.sidebar.collapsedMachines",
        ]
        let saved = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            for key in keys {
                if let value = saved[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(try JSONEncoder().encode([HerdrMachine]()), forKey: "herdr.machines")
        defaults.set(false, forKey: "herdr.demoMode")
        defaults.set(false, forKey: "herdr.completedSetup")
        defaults.removeObject(forKey: "herdr.machineScope")
        defaults.removeObject(forKey: "herdr.sidebar.starredChats")
        defaults.removeObject(forKey: "herdr.sidebar.collapsedWorkspaces")
        defaults.removeObject(forKey: "herdr.sidebar.collapsedMachines")
        try body(HerdrAppModel(arguments: [], userDefaults: defaults), defaults)
    }
}
