import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Herdr font scale")
struct HerdrFontScaleTests {
    @Test("Stepping from medium follows the ordered ladder")
    func steppingFromMedium() {
        #expect(HerdrFontScale.medium.increased == .large)
        #expect(HerdrFontScale.medium.decreased == .small)
    }

    @Test("Stepping beyond the largest scale clamps")
    func largestScaleClamps() {
        #expect(HerdrFontScale.xxxLarge.increased == .xxxLarge)
    }

    @Test("Stepping below the smallest scale clamps")
    func smallestScaleClamps() {
        #expect(HerdrFontScale.small.decreased == .small)
    }

    @Test("Default scale preserves existing rendering")
    func defaultScaleIsMedium() {
        #expect(HerdrFontScale.default == .medium)
        #expect(HerdrFontScale.default.rawValue == 1.0)
    }

    @Test("Font scale uses its stable defaults key")
    func defaultsKey() {
        #expect(HerdrFontScale.defaultsKey == "herdr.mac.fontScale")
    }

    @Test("Scale persistence round-trips and empty defaults use the default")
    func persistenceRoundTrip() throws {
        let suiteName = "HerdrFontScaleTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(HerdrFontScale.load(from: defaults) == .default)
        HerdrFontScale.xxLarge.save(to: defaults)
        #expect(HerdrFontScale.load(from: defaults) == .xxLarge)
    }

    @MainActor
    @Test("Scale store updates and persists its selected scale")
    func storeMutationsPersist() throws {
        let suiteName = "HerdrFontScaleTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = HerdrFontScaleStore(defaults: defaults)

        store.increase()
        #expect(store.scale == .large)
        #expect(defaults.double(forKey: HerdrFontScale.defaultsKey) == HerdrFontScale.large.rawValue)

        store.decrease()
        #expect(store.scale == .medium)

        store.increase()
        store.reset()
        #expect(store.scale == .default)
        #expect(HerdrFontScaleStore(defaults: defaults).scale == .default)
    }
}
