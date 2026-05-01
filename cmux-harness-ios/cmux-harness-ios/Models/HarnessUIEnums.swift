import Foundation

enum HarnessKey: String, CaseIterable, Equatable, Identifiable, Sendable {
    case up
    case down
    case tab
    case enter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .up:
            return "Up"
        case .down:
            return "Down"
        case .tab:
            return "Tab"
        case .enter:
            return "Enter"
        }
    }

    var systemImage: String {
        switch self {
        case .up:
            return "arrow.up"
        case .down:
            return "arrow.down"
        case .tab:
            return "arrow.right.to.line"
        case .enter:
            return "return"
        }
    }
}

enum DetailTab: String, CaseIterable, Equatable, Identifiable, Sendable {
    case terminal
    case git
    case activity
    case skills

    var id: String { rawValue }

    var label: String {
        switch self {
        case .terminal:
            return "Terminal"
        case .git:
            return "Git"
        case .activity:
            return "Activity"
        case .skills:
            return "Skills"
        }
    }
}

enum GitFileSection: String, Equatable, Identifiable, Sendable {
    case staged
    case unstaged
    case untracked

    var id: String { rawValue }

    var label: String {
        switch self {
        case .staged:
            return "Staged"
        case .unstaged:
            return "Unstaged"
        case .untracked:
            return "Untracked"
        }
    }
}

enum GitDetailSegment: String, CaseIterable, Equatable, Identifiable, Sendable {
    case status
    case prComments

    var id: String { rawValue }

    var label: String {
        switch self {
        case .status:
            return "Status"
        case .prComments:
            return "PR Comments"
        }
    }
}

enum NewSessionMode: String, CaseIterable, Equatable, Identifiable, Sendable {
    case claude
    case shell

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude:
            return "Claude"
        case .shell:
            return "Shell"
        }
    }
}
