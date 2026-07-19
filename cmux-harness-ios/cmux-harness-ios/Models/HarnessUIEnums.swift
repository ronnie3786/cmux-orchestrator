import Foundation

enum HarnessKey: String, CaseIterable, Equatable, Identifiable, Sendable {
    case up
    case down
    case tab
    case enter
    case left
    case right
    case space
    case escape
    case backspace

    var id: String { rawValue }

    static var inputRows: [[HarnessKey]] {
        [
            [.up, .down, .tab, .enter],
            [.left, .right, .escape, .backspace],
        ]
    }

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
        case .left:
            return "Left"
        case .right:
            return "Right"
        case .space:
            return "Space"
        case .escape:
            return "Esc"
        case .backspace:
            return "Bkspc"
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
        case .left:
            return "arrow.left"
        case .right:
            return "arrow.right"
        case .space:
            return "keyboard"
        case .escape:
            return "x.square"
        case .backspace:
            return "delete.left"
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
