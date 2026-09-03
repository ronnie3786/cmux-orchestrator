import Foundation

struct NavigationHistorySnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let empty = NavigationHistorySnapshot(version: currentVersion, backward: [], current: nil, forward: [])

    let version: Int
    let backward: [HerdrDestinationRecord]
    let current: HerdrDestinationRecord?
    let forward: [HerdrDestinationRecord]
}

struct NavigationHistoryPersistenceStore {
    static let defaultsKey = "herdr.navigation.history"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// Total: a missing key, malformed JSON, or an unrecognized `version` all
    /// yield `.empty` rather than throwing; a corrupt or future-versioned
    /// snapshot must never crash launch or block the shell from starting.
    func load() -> NavigationHistorySnapshot {
        guard let data = userDefaults.data(forKey: Self.defaultsKey),
              let snapshot = try? JSONDecoder().decode(NavigationHistorySnapshot.self, from: data),
              snapshot.version == NavigationHistorySnapshot.currentVersion
        else {
            return .empty
        }
        return snapshot
    }

    func save(_ snapshot: NavigationHistorySnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        userDefaults.set(data, forKey: Self.defaultsKey)
    }
}
