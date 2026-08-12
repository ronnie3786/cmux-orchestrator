import Foundation

enum PaneDetailMode: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case terminal
    case git
    case skills

    var id: String { rawValue }

    var label: String {
        switch self {
        case .terminal: "Terminal"
        case .git: "Git"
        case .skills: "Skills"
        }
    }

    var symbol: String {
        switch self {
        case .terminal: "terminal"
        case .git: "point.3.connected.trianglepath.dotted"
        case .skills: "wand.and.stars"
        }
    }
}
