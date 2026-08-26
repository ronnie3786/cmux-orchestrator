import Foundation

enum WorkInboxJiraStatus: Int, Sendable {
    case inProgress
    case codeReview
    case blocked
    case queued
    case other

    init(name: String) {
        let normalized = name.lowercased()
        if normalized.contains("progress") {
            self = .inProgress
        } else if normalized.contains("review") {
            self = .codeReview
        } else if normalized.contains("block") {
            self = .blocked
        } else if normalized.contains("todo") || normalized.contains("to do")
                    || normalized.contains("backlog") || normalized.contains("selected") {
            self = .queued
        } else {
            self = .other
        }
    }

    var symbolName: String {
        switch self {
        case .inProgress: "circle.dotted"
        case .codeReview: "arrow.triangle.branch"
        case .blocked: "exclamationmark.octagon.fill"
        case .queued: "circle"
        case .other: "circle.lefthalf.filled"
        }
    }
}
