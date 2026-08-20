import Foundation

enum PiPromptDisposition: String, CaseIterable, Identifiable, Sendable {
    case prompt
    case steer
    case followUp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .prompt: "Send"
        case .steer: "Steer"
        case .followUp: "Follow up"
        }
    }

    var shortLabel: String {
        switch self {
        case .prompt: "Send"
        case .steer: "Steer"
        case .followUp: "Next"
        }
    }

    var symbol: String {
        switch self {
        case .prompt: "arrow.up"
        case .steer: "arrow.triangle.turn.up.right.diamond.fill"
        case .followUp: "text.append"
        }
    }
}
