import Foundation

struct PiAvailableModel: Codable, Equatable, Hashable, Sendable, Identifiable {
    let provider: String
    let modelID: String
    let name: String?
    let reasoning: Bool?
    let contextWindow: Int?

    var id: String { "\(provider)/\(modelID)" }
    var displayName: String { name?.nonEmpty ?? modelID }

    enum CodingKeys: String, CodingKey {
        case provider
        case modelID = "id"
        case name
        case reasoning
        case contextWindow
        case contextWindowSnake = "context_window"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(String.self, forKey: .provider)
        modelID = try container.decode(String.self, forKey: .modelID)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        reasoning = try container.decodeIfPresent(Bool.self, forKey: .reasoning)
        contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow)
            ?? container.decodeIfPresent(Int.self, forKey: .contextWindowSnake)
    }

    init(provider: String, modelID: String, name: String?, reasoning: Bool?, contextWindow: Int?) {
        self.provider = provider
        self.modelID = modelID
        self.name = name
        self.reasoning = reasoning
        self.contextWindow = contextWindow
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(modelID, forKey: .modelID)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(reasoning, forKey: .reasoning)
        try container.encodeIfPresent(contextWindow, forKey: .contextWindow)
    }
}

struct PiModelCatalogResponse: Decodable, Sendable {
    let accepted: Bool
    let models: [PiAvailableModel]
    let current: PiModelIdentity?

    enum CodingKeys: String, CodingKey {
        case ok
        case success
        case result
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accepted = try container.decodeIfPresent(Bool.self, forKey: .ok)
            ?? container.decodeIfPresent(Bool.self, forKey: .success)
            ?? false
        if let result = try container.decodeIfPresent(PiModelCatalogResult.self, forKey: .result) {
            models = result.models
            current = result.current
        } else {
            models = []
            current = nil
        }
    }
}

private struct PiModelCatalogResult: Decodable, Sendable {
    let models: [PiAvailableModel]
    let current: PiModelIdentity?

    enum CodingKeys: String, CodingKey {
        case models
        case current
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        models = try container.decodeIfPresent([PiAvailableModel].self, forKey: .models) ?? []
        if let currentValue = try container.decodeIfPresent(PiJSONValue.self, forKey: .current) {
            current = PiModelIdentity(json: currentValue)
        } else {
            current = nil
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
