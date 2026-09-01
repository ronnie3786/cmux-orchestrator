import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Agent model settings")
struct AgentModelSettingsStoreTests {
    @Test("Empty defaults use the documented agent defaults")
    func defaults() throws {
        let suiteName = "AgentModelSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AgentModelSettings.load(from: defaults)
        #expect(settings.hudModel == "")
        #expect(settings.quickChatModel == "")
        #expect(settings.visionModel == "")
        #expect(settings.thinkingLevel == .max)
        #expect(settings.effectiveVisionModel == AgentModelSettings.builtInVisionModel)
    }

    @MainActor
    @Test("Store mutations persist a complete settings snapshot")
    func storeMutationsPersist() throws {
        let suiteName = "AgentModelSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AgentModelSettingsStore(defaults: defaults)

        store.hudModel = "openai-codex/gpt-5.6-luna"
        store.quickChatModel = "anthropic/claude-sonnet-4-5"
        store.visionModel = "custom/vision"
        store.thinkingLevel = .low

        let loaded = AgentModelSettings.load(from: defaults)
        #expect(loaded.hudModel == "openai-codex/gpt-5.6-luna")
        #expect(loaded.quickChatModel == "anthropic/claude-sonnet-4-5")
        #expect(loaded.visionModel == "custom/vision")
        #expect(loaded.thinkingLevel == .low)
    }

    @MainActor
    @Test("HUD model shares the legacy HUD key")
    func hudModelSharesTheLegacyHudKey() throws {
        let suiteName = "AgentModelSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("p/m", forKey: "herdr.hud.model")

        let store = AgentModelSettingsStore(defaults: defaults)
        #expect(store.hudModel == "p/m")
    }

    @Test("Invalid stored thinking level falls back to max")
    func invalidStoredThinkingLevelFallsBackToMax() throws {
        let suiteName = "AgentModelSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("bananas", forKey: "herdr.agent.thinkingLevel")

        #expect(AgentModelSettings.load(from: defaults).thinkingLevel == .max)
    }
}
