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

    @Test("A verbatim blank override is stored but text falls back to the default")
    func storesBlankOverride() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let id = HerdrPromptID.notesSmartActions
        let store = HerdrPromptSettingsStore(defaults: defaults)
        store.setText("   \n", for: id)
        #expect(store.isCustomized(id))
        #expect(store.override(for: id) == nil)
        #expect(store.text(for: id) == id.builtInDefault)
        #expect(defaults.string(forKey: id.defaultsKey) == "   \n")
    }

    @Test("Setting text equal to the current default removes the override")
    func defaultTextRemovesOverride() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let id = HerdrPromptID.notesSmartActions
        let store = HerdrPromptSettingsStore(defaults: defaults)
        store.setText("Custom", for: id)
        store.setText(id.builtInDefault, for: id)
        #expect(store.override(for: id) == nil)
        #expect(!store.isCustomized(id))
        #expect(defaults.object(forKey: id.defaultsKey) == nil)
    }

    @Test("Stored override filters blank text")
    func storedOverrideFiltersBlankText() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let id = HerdrPromptID.notesSmartActions
        defaults.set("Direct text", forKey: id.defaultsKey)
        #expect(HerdrPromptSettingsStore.storedOverride(for: id, defaults: defaults) == "Direct text")
        defaults.set(" \n", forKey: id.defaultsKey)
        #expect(HerdrPromptSettingsStore.storedOverride(for: id, defaults: defaults) == nil)
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
