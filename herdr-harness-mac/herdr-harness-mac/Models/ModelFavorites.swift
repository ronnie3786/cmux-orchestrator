import Foundation
import Observation

struct ModelFavorites: Equatable, Sendable {
    private(set) var ids: [String]

    init(ids: [String] = []) {
        var uniqueIDs: [String] = []
        for id in ids where !id.isEmpty && !uniqueIDs.contains(id) {
            uniqueIDs.append(id)
        }
        self.ids = uniqueIDs
    }

    func contains(_ id: String) -> Bool {
        ids.contains(id)
    }

    func toggling(_ id: String) -> ModelFavorites {
        guard !id.isEmpty else { return self }
        var updated = ids
        if let index = updated.firstIndex(of: id) {
            updated.remove(at: index)
        } else {
            updated.append(id)
        }
        return ModelFavorites(ids: updated)
    }
}

@MainActor
@Observable
final class ModelFavoritesStore {
    static let defaultsKey = "herdr.models.favorites"

    private(set) var ids: [String] {
        didSet { defaults.set(ids, forKey: Self.defaultsKey) }
    }
    @ObservationIgnored private let defaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        defaults = userDefaults
        ids = ModelFavorites(ids: userDefaults.array(forKey: Self.defaultsKey) as? [String] ?? []).ids
    }

    func isFavorite(_ id: String) -> Bool {
        ids.contains(id)
    }

    func toggle(_ id: String) {
        guard !id.isEmpty else { return }
        ids = ModelFavorites(ids: ids).toggling(id).ids
    }

    nonisolated static func ordered(_ models: [PiAvailableModel], favorites: [String]) -> [PiAvailableModel] {
        var modelsByID: [String: PiAvailableModel] = [:]
        for model in models where modelsByID[model.id] == nil {
            modelsByID[model.id] = model
        }
        return ModelFavorites(ids: favorites).ids.compactMap { modelsByID[$0] }
    }
}
