import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Herdr machine migration", .serialized)
@MainActor
struct HerdrMachineMigrationTests {
    @Test("Legacy connection migrates once without losing state")
    func legacyMigration() throws {
        let suiteName = "herdr-machine-migration-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let legacyToken = KeychainStore.value(for: "api-token")
        var migratedID: String?
        defer {
            KeychainStore.set(legacyToken, for: "api-token")
            if let migratedID { KeychainStore.removeValue(for: "api-token.\(migratedID)") }
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        defaults.set("https://ronniesitym4mbp.tail1db61d.ts.net:8444", forKey: "herdr.serverURL")
        defaults.set(["w1:p1"], forKey: "herdr.sidebar.starredChats")
        defaults.set(["w1"], forKey: "herdr.sidebar.collapsedWorkspaces")
        KeychainStore.set("legacy-token", for: "api-token")
        let first = HerdrAppModel(arguments: [], userDefaults: defaults)
        let machine = try #require(first.machines.count == 1 ? first.machines[0] : nil)
        migratedID = machine.id
        #expect(machine.name == "ronniesitym4mbp")
        #expect(machine.urlString == "https://ronniesitym4mbp.tail1db61d.ts.net:8444")
        #expect(KeychainStore.value(for: "api-token.\(machine.id)") == "legacy-token")
        #expect(KeychainStore.value(for: "api-token") == "legacy-token")
        #expect(defaults.stringArray(forKey: "herdr.sidebar.starredChats") == ["\(machine.id)|w1:p1"])
        #expect(defaults.stringArray(forKey: "herdr.sidebar.collapsedWorkspaces") == ["\(machine.id)|w1"])
        let second = HerdrAppModel(arguments: [], userDefaults: defaults)
        #expect(second.machines.count == 1)
        #expect(defaults.stringArray(forKey: "herdr.sidebar.starredChats") == ["\(machine.id)|w1:p1"])
        #expect(defaults.stringArray(forKey: "herdr.sidebar.collapsedWorkspaces") == ["\(machine.id)|w1"])
    }

    @Test("Fresh install records an empty machine list")
    func freshMigration() {
        let suiteName = "herdr-machine-migration-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        defaults.set(false, forKey: "herdr.completedSetup")
        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        #expect(model.machines.isEmpty)
        #expect(defaults.data(forKey: "herdr.machines") != nil)
        #expect(!model.hasCompletedSetup)
    }
}
