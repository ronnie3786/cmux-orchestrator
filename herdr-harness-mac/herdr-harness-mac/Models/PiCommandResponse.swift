import Foundation

struct PiCommandResponse: Decodable, Sendable {
    let accepted: Bool

    enum CodingKeys: String, CodingKey {
        case ok
        case success
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accepted = try container.decodeIfPresent(Bool.self, forKey: .ok)
            ?? container.decodeIfPresent(Bool.self, forKey: .success)
            ?? false
    }
}
