import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Cleanup settings")
struct CleanupSettingsStoreTests {
    @Test("Empty defaults use the documented cleanup defaults")
    func defaults() throws {
        let suiteName = "CleanupSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = CleanupSettings.load(from: defaults)
        #expect(settings.model == "")
        #expect(settings.thinkingLevel == .medium)
        #expect(settings.costThresholdUSD == 2.0)
    }

    @MainActor
    @Test("Store mutations persist a complete settings snapshot")
    func storeMutationsPersist() throws {
        let suiteName = "CleanupSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CleanupSettingsStore(defaults: defaults)

        store.model = "custom-lux-dspark/qwen"
        store.thinkingLevel = .high
        store.costThresholdUSD = 3.41

        let loaded = CleanupSettings.load(from: defaults)
        #expect(loaded.model == "custom-lux-dspark/qwen")
        #expect(loaded.thinkingLevel == .high)
        #expect(loaded.costThresholdUSD == 3.41)
    }
}
