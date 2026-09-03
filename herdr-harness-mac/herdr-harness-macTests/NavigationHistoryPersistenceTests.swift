import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Navigation history persistence")
struct NavigationHistoryPersistenceTests {
    @Test("Save then load preserves backward, current, and forward order")
    func saveThenLoadPreservesOrder() throws {
        let suiteName = "NavigationHistoryPersistenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = NavigationHistoryPersistenceStore(userDefaults: defaults)
        let snapshot = NavigationHistorySnapshot(
            version: NavigationHistorySnapshot.currentVersion,
            backward: [HerdrDestinationRecord(.pane("a"))!, HerdrDestinationRecord(.pane("b"))!],
            current: HerdrDestinationRecord(.workspace("w1")),
            forward: [HerdrDestinationRecord(.activity)!]
        )

        store.save(snapshot)

        #expect(store.load() == snapshot)
    }

    @Test("A missing key loads an empty snapshot")
    func missingKeyLoadsEmptySnapshot() throws {
        let suiteName = "NavigationHistoryPersistenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = NavigationHistoryPersistenceStore(userDefaults: defaults)

        #expect(store.load() == .empty)
    }

    @Test("A future-version snapshot loads an empty snapshot")
    func futureVersionSnapshotLoadsEmptySnapshot() throws {
        let suiteName = "NavigationHistoryPersistenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let futureSnapshot = NavigationHistorySnapshot(version: 2, backward: [], current: nil, forward: [])
        let data = try JSONEncoder().encode(futureSnapshot)
        defaults.set(data, forKey: NavigationHistoryPersistenceStore.defaultsKey)

        #expect(NavigationHistoryPersistenceStore(userDefaults: defaults).load() == .empty)
    }

    @Test("Malformed JSON loads an empty snapshot")
    func malformedJSONLoadsEmptySnapshot() throws {
        let suiteName = "NavigationHistoryPersistenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Data("not json {".utf8), forKey: NavigationHistoryPersistenceStore.defaultsKey)

        #expect(NavigationHistoryPersistenceStore(userDefaults: defaults).load() == .empty)
    }
}
