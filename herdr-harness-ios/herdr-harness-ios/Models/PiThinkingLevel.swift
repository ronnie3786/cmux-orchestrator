import Foundation

enum PiThinkingLevel: String, CaseIterable, Codable, Sendable {
    case off
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max

    var displayName: String {
        switch self {
        case .off: "Off"
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra High"
        case .max: "Max"
        }
    }
}

struct PiSetThinkingLevelResponse: Decodable, Sendable {
    let accepted: Bool
    let level: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case success
        case result
    }

    enum ResultKeys: String, CodingKey {
        case level
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accepted = try container.decodeIfPresent(Bool.self, forKey: .ok)
            ?? container.decodeIfPresent(Bool.self, forKey: .success)
            ?? false
        if let result = try? container.nestedContainer(keyedBy: ResultKeys.self, forKey: .result) {
            level = try result.decodeIfPresent(String.self, forKey: .level)
        } else {
            level = nil
        }
    }
}
