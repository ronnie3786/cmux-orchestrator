import Foundation
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("Herdr prompt settings")
struct HerdrPromptSettingsStoreTests {
    @Test("Fresh settings use each built-in default")
    func defaults() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = HerdrPromptSettingsStore(defaults: defaults)
        for id in HerdrPromptID.allCases {
            #expect(store.text(for: id) == id.builtInDefault)
            #expect(!store.isCustomized(id))
        }
    }

    @Test("A custom prompt persists and is restored")
    func persistsOverride() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let id = HerdrPromptID.notesCleanup
        let store = HerdrPromptSettingsStore(defaults: defaults)
        store.setText("Custom cleanup", for: id)
        #expect(store.isCustomized(id))
        #expect(defaults.string(forKey: id.defaultsKey) == "Custom cleanup")
        #expect(HerdrPromptSettingsStore(defaults: defaults).override(for: id) == "Custom cleanup")
    }

    @Test("Blank or default text clears an existing override")
    func clearingOverride() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let id = HerdrPromptID.notesSmartActions
        let store = HerdrPromptSettingsStore(defaults: defaults)
        store.setText("Custom", for: id)
        store.setText("  \n", for: id)
        #expect(store.override(for: id) == nil)
        store.setText("Custom again", for: id)
        store.setText(id.builtInDefault, for: id)
        #expect(store.override(for: id) == nil)
    }

    @Test("Reset restores the default and removes storage")
    func reset() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let id = HerdrPromptID.notesTakeAction
        let store = HerdrPromptSettingsStore(defaults: defaults)
        store.setText("Custom", for: id)
        store.reset(id)
        #expect(store.text(for: id) == id.builtInDefault)
        #expect(defaults.object(forKey: id.defaultsKey) == nil)
    }

    @Test("Demo harness prompt defaults are loaded")
    func loadsDemoHarnessDefaults() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = HerdrPromptSettingsStore(defaults: defaults)
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"], userDefaults: defaults)
        await store.loadHarnessDefaults(model: model)
        #expect(store.harnessSupportsOverrides == true)
        #expect(store.harnessDefaults[.hudActCharter] == HerdrPromptID.hudActCharter.builtInDefault)
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suiteName = "HerdrPromptSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
