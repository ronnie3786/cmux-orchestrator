import Foundation

struct PiSemanticCapabilities: Codable, Equatable, Hashable, Sendable {
    let prompt: Bool
    let steer: Bool
    let followUp: Bool
    let abort: Bool
    let interactionResponse: Bool

    static let unavailable = PiSemanticCapabilities(
        prompt: false,
        steer: false,
        followUp: false,
        abort: false,
        interactionResponse: false
    )

    init(
        prompt: Bool,
        steer: Bool,
        followUp: Bool,
        abort: Bool,
        interactionResponse: Bool
    ) {
        self.prompt = prompt
        self.steer = steer
        self.followUp = followUp
        self.abort = abort
        self.interactionResponse = interactionResponse
    }

    enum CodingKeys: String, CodingKey {
        case prompt
        case steer
        case followUp
        case followUpSnake = "follow_up"
        case abort
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
        try container.encode(interactionResponse, forKey: .interactionResponse)
    }
}
