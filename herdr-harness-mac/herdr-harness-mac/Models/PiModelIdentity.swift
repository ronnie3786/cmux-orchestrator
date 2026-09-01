import Foundation

struct PiModelIdentity: Codable, Equatable, Hashable, Sendable {
    let provider: String
    let id: String
    let name: String?

    var displayName: String { name?.nonEmpty ?? id }

    /// Matches `PiAvailableModel.id`, so a stored preference can be compared
    /// against the catalog's own `default` entry.
    var fullID: String { "\(provider)/\(id)" }

    init(provider: String, id: String, name: String?) {
        self.provider = provider
        self.id = id
        self.name = name
    }

    init?(json: PiJSONValue?) {
        guard let provider = json?.string(for: "provider"),
              let id = json?.string(for: "id", "modelId", "model_id")
        else { return nil }
        self.provider = provider
        self.id = id
        self.name = json?.string(for: "name")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
