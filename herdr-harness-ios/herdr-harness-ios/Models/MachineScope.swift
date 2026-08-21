import Foundation

enum MachineScope: Equatable {
    case all
    case machine(String)

    static func load(from defaults: UserDefaults = .standard) -> MachineScope {
        guard let value = defaults.string(forKey: "herdr.machineScope"), value != "all" else {
            return .all
        }
        return .machine(value)
    }

    func save(to defaults: UserDefaults = .standard) {
        switch self {
        case .all: defaults.set("all", forKey: "herdr.machineScope")
        case let .machine(id): defaults.set(id, forKey: "herdr.machineScope")
        }
    }
}
