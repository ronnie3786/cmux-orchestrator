import Foundation

struct PiSemanticCapabilities: Codable, Equatable, Hashable, Sendable {
    let prompt: Bool
    let steer: Bool
    let followUp: Bool
    let abort: Bool
    let compact: Bool
    let listModels: Bool
    let setModel: Bool
    let setThinkingLevel: Bool
    let interactionResponse: Bool

    static let unavailable = PiSemanticCapabilities(
        prompt: false,
        steer: false,
        followUp: false,
        abort: false,
        compact: false,
        listModels: false,
        setModel: false,
        setThinkingLevel: false,
        interactionResponse: false
    )

    init(
        prompt: Bool,
        steer: Bool,
        followUp: Bool,
        abort: Bool,
        compact: Bool = false,
        listModels: Bool,
        setModel: Bool,
        setThinkingLevel: Bool,
        interactionResponse: Bool
    ) {
        self.prompt = prompt
        self.steer = steer
        self.followUp = followUp
        self.abort = abort
        self.compact = compact
        self.listModels = listModels
        self.setModel = setModel
        self.setThinkingLevel = setThinkingLevel
        self.interactionResponse = interactionResponse
    }

    enum CodingKeys: String, CodingKey {
        case prompt
        case steer
        case followUp
        case followUpSnake = "follow_up"
        case abort
        case compact
        case listModels
        case listModelsSnake = "list_models"
        case setModel
        case setModelSnake = "set_model"
        case setThinkingLevel
        case setThinkingLevelSnake = "set_thinking_level"
        case interactionResponse
        case interactionResponseSnake = "interaction_response"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try container.decodeIfPresent(Bool.self, forKey: .prompt) ?? false
        steer = try container.decodeIfPresent(Bool.self, forKey: .steer) ?? false
        followUp = try container.decodeIfPresent(Bool.self, forKey: .followUp)
            ?? container.decodeIfPresent(Bool.self, forKey: .followUpSnake)
            ?? false
        abort = try container.decodeIfPresent(Bool.self, forKey: .abort) ?? false
        compact = try container.decodeIfPresent(Bool.self, forKey: .compact) ?? false
        listModels = try container.decodeIfPresent(Bool.self, forKey: .listModels)
            ?? container.decodeIfPresent(Bool.self, forKey: .listModelsSnake)
            ?? false
        setModel = try container.decodeIfPresent(Bool.self, forKey: .setModel)
            ?? container.decodeIfPresent(Bool.self, forKey: .setModelSnake)
            ?? false
        setThinkingLevel = try container.decodeIfPresent(Bool.self, forKey: .setThinkingLevel)
            ?? container.decodeIfPresent(Bool.self, forKey: .setThinkingLevelSnake)
            ?? false
        interactionResponse = try container.decodeIfPresent(Bool.self, forKey: .interactionResponse)
            ?? container.decodeIfPresent(Bool.self, forKey: .interactionResponseSnake)
            ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(steer, forKey: .steer)
        try container.encode(followUp, forKey: .followUp)
        try container.encode(abort, forKey: .abort)
        try container.encode(compact, forKey: .compact)
        try container.encode(listModels, forKey: .listModels)
        try container.encode(setModel, forKey: .setModel)
        try container.encode(setThinkingLevel, forKey: .setThinkingLevel)
        try container.encode(interactionResponse, forKey: .interactionResponse)
    }
}
