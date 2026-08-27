import Foundation

enum PaneDetailMode: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case chat
    case terminal
    case git
    case skills

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chat: "Chat"
        case .terminal: "Terminal"
        case .git: "Git"
        case .skills: "Skills"
        }
    }

    var symbol: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .terminal: "terminal"
        case .git: "arrow.triangle.branch"
        case .skills: "wand.and.stars"
        }
    }
}
