import Foundation

struct RefreshPayload: Equatable, Sendable {
    var status: HarnessStatus
    var log: [LogEntry]
}

struct HarnessStatus: Decodable, Equatable, Sendable {
    var enabled: Bool
    var workspaces: [Workspace]
    var pollInterval: Int
    var socketFound: Bool
    var model: String?
    var reviewEnabled: Bool?
    var reviewModel: String?
    var reviewBackend: String?
    var contractReviewEnabled: Bool?
    var connected: Bool?
    var lastSuccessfulPoll: Double?
    var connectionLostAt: Double?
    var staleData: Bool?
    var ollamaAvailable: Bool?
}

struct Workspace: Decodable, Equatable, Identifiable, Sendable {
    var hasClaude: Bool
    var index: Int
    var name: String
    var uuid: String
    var enabled: Bool
    var customName: String?
    var lastCheck: String?
    var screenTail: String?
    var screenFull: String?
    var cwd: String?
    var branch: String?
    var sessionStart: Double?
    var sessionCost: String?
    var surfaceId: String?
    var surfaceLabel: String?
    var surfaceTitle: String?
    var gitDirty: Bool?
    var surfaceCreatedAt: String?
    var surfaceAge: Double?

    var id: String {
        let stableID = uuid.isEmpty ? "index-\(index)" : uuid
        return [stableID, surfaceId ?? "", String(index)].joined(separator: "|")
    }

    var displayName: String {
        let value = surfaceLabel ?? customName ?? name
        return value.isEmpty ? "workspace-\(index)" : value
    }

    var terminalPreview: String {
        let text = screenTail ?? screenFull ?? ""
        return text.isEmpty ? "(no terminal data yet)" : text
    }
}

struct LogEntry: Decodable, Equatable, Identifiable, Sendable {
    var timestamp: String?
    var workspace: Int?
    var workspaceName: String?
    var promptType: String?
    var action: String?
    var reason: String?
    var key: String?
    var surfaceId: String?
    var sessionID: String?

    var id: String {
        [
            timestamp ?? "",
            workspace.map(String.init) ?? "",
            action ?? "",
            promptType ?? "",
            key ?? "",
        ].joined(separator: "|")
    }

    enum CodingKeys: String, CodingKey {
        case timestamp
        case workspace
        case workspaceName
        case promptType
        case action
        case reason
        case key
        case surfaceId
        case sessionID = "session_id"
    }
}

struct ScreenResponse: Decodable, Equatable, Sendable {
    var ok: Bool
    var screen: String
    var lines: Int?
    var error: String?
}

struct BasicResponse: Decodable, Equatable, Sendable {
    var ok: Bool
    var enabled: Bool?
    var error: String?
}

struct NewSessionResponse: Decodable, Equatable, Sendable {
    struct CreatedWorkspace: Decodable, Equatable, Sendable {
        var index: Int?
        var uuid: String?
    }

    var ok: Bool
    var workspace: CreatedWorkspace?
    var worktreePath: String?
    var branchName: String?
    var error: String?
}

struct GitStatus: Decodable, Equatable, Sendable {
    var ok: Bool?
    var branch: String?
    var cwd: String?
    var staged: [GitFile]
    var unstaged: [GitFile]
    var untracked: [String]
    var commits: [GitCommit]
    var error: String?

    var hasChanges: Bool {
        !staged.isEmpty || !unstaged.isEmpty || !untracked.isEmpty
    }
}

struct GitFile: Decodable, Equatable, Identifiable, Sendable {
    var status: String
    var file: String

    var id: String { "\(status)|\(file)" }
}

struct GitCommit: Decodable, Equatable, Identifiable, Sendable {
    var hash: String
    var message: String

    var id: String { "\(hash)|\(message)" }
}

struct GitDiffResponse: Decodable, Equatable, Sendable {
    var ok: Bool
    var diff: String?
    var error: String?
}

struct DiffSheet: Equatable, Identifiable, Sendable {
    var id = UUID()
    var file: String
    var section: GitFileSection
    var diff: String
    var isLoading: Bool
    var error: String?
}

enum WorkspaceSessionState: String, Equatable, Sendable {
    case active
    case waiting
    case idle

    var label: String {
        switch self {
        case .active:
            return "Active"
        case .waiting:
            return "Needs You"
        case .idle:
            return "Idle"
        }
    }

    var systemImage: String {
        switch self {
        case .active:
            return "play.circle.fill"
        case .waiting:
            return "exclamationmark.circle.fill"
        case .idle:
            return "pause.circle.fill"
        }
    }
}

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

    var id: String { rawValue }

    var label: String {
        switch self {
        case .terminal:
            return "Terminal"
        case .git:
            return "Git"
        case .activity:
            return "Activity"
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
