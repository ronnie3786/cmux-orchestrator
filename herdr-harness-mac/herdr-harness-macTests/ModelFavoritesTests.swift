import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Model favorites")
struct ModelFavoritesTests {
    @MainActor
    @Test("Toggles preserve insertion order")
    func insertionOrder() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        store.toggle("A"); store.toggle("B"); store.toggle("C")
        #expect(store.ids == ["A", "B", "C"])
        store.toggle("B"); store.toggle("B")
        #expect(store.ids == ["A", "C", "B"])
    }

    @MainActor
    @Test("Toggle removes an existing favorite")
    func toggleOff() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        store.toggle("A"); store.toggle("A")
        #expect(!store.isFavorite("A"))
        #expect(store.ids.isEmpty)
    }

    @MainActor
    @Test("Capacity retains the newest twelve favorites")
    func capacity() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        for index in 0...12 { store.toggle("M\(index)") }
        #expect(store.ids == (1...12).map { "M\($0)" })
    }

    @Test("Ordering skips stale favorites")
    func orderedModels() {
        let models = [model("A"), model("B"), model("C")]
        let ordered = ModelFavoritesStore.ordered(models, favorites: [models[2].id, "missing/model", models[0].id])
        #expect(ordered.map(\.id) == [models[2].id, models[0].id])
    }

    @MainActor
    @Test("Favorites persist across store instances")
    func persistence() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        store.toggle("A"); store.toggle("B")
        let reloaded = ModelFavoritesStore(userDefaults: defaults)
        #expect(reloaded.ids == ["A", "B"])
    }

    @MainActor
    @Test("Garbage defaults load as empty")
    func garbageDefaults() throws {
        let (_, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("not an array", forKey: ModelFavoritesStore.defaultsKey)
        #expect(ModelFavoritesStore(userDefaults: defaults).ids.isEmpty)
        defaults.set(12, forKey: ModelFavoritesStore.defaultsKey)
        #expect(ModelFavoritesStore(userDefaults: defaults).ids.isEmpty)
    }

    @MainActor
    private func makeStore() throws -> (ModelFavoritesStore, UserDefaults, String) {
        let suiteName = "ModelFavoritesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (ModelFavoritesStore(userDefaults: defaults), defaults, suiteName)
    }

    private func model(_ modelID: String) -> PiAvailableModel {
        PiAvailableModel(provider: "provider", modelID: modelID, name: nil, reasoning: nil, contextWindow: nil)
    }
}
