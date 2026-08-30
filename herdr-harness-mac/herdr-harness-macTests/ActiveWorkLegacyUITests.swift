import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Active Work legacy UI flag", .serialized)
@MainActor
struct ActiveWorkLegacyUITests {
    @Test("Defaults to the embedded board")
    func defaultsToEmbeddedBoard() throws {
        let defaults = try makeDefaults()
        #expect(HerdrAppModel(arguments: [], userDefaults: defaults).activeWorkLegacyUI == false)
    }

    @Test("Launch argument enables the legacy board")
    func launchArgumentEnablesLegacyBoard() throws {
        let defaults = try makeDefaults()
        #expect(
            HerdrAppModel(arguments: ["-HerdrActiveWorkLegacy"], userDefaults: defaults).activeWorkLegacyUI
        )
    }

    @Test("Persisted true enables the legacy board")
    func persistedTrueEnablesLegacyBoard() throws {
        let defaults = try makeDefaults()
        defaults.set(true, forKey: "herdr.activeWork.legacy")
        #expect(HerdrAppModel(arguments: [], userDefaults: defaults).activeWorkLegacyUI)
    }

    @Test("Persisted false keeps the embedded board")
    func persistedFalseKeepsEmbeddedBoard() throws {
        let defaults = try makeDefaults()
        defaults.set(false, forKey: "herdr.activeWork.legacy")
        #expect(HerdrAppModel(arguments: [], userDefaults: defaults).activeWorkLegacyUI == false)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "ActiveWorkLegacyUITests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
