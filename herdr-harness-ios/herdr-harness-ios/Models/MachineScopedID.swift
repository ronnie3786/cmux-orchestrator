import Foundation

enum MachineScopedID {
    static let separator: Character = "|"

    static func compose(machineID: String, rawID: String) -> String {
        "\(machineID)\(separator)\(rawID)"
    }

    static func split(_ id: String) -> (machineID: String, rawID: String)? {
        guard let index = id.firstIndex(of: separator) else { return nil }
        return (String(id[..<index]), String(id[id.index(after: index)...]))
    }
}
