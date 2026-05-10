import Foundation

enum HarnessMode: String, CaseIterable, Identifiable {
    case managedServer = "Managed Server"
    case externalServer = "External Server"
    case localDemo = "Local Demo"

    var id: String { rawValue }
}

enum ServerPhase: Equatable {
    case stopped
    case starting
    case running
    case unhealthy(String)
    case crashed(String)

    var label: String {
        switch self {
        case .stopped:
            "Stopped"
        case .starting:
            "Starting"
        case .running:
            "Running"
        case .unhealthy:
            "Unhealthy"
        case .crashed:
            "Crashed"
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

enum WorkspaceAutoMode: String, Codable, CaseIterable, Identifiable {
    case off
    case auto
    case superAuto = "super"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off:
            "Off"
        case .auto:
            "Auto"
        case .superAuto:
            "Super"
        }
    }

    var isEnabled: Bool { self != .off }
}

enum NewSessionMode: String, CaseIterable, Identifiable {
    case claude = "Claude"
    case shell = "Shell"

    var id: String { rawValue }
}

struct HarnessStatus: Codable {
    var enabled: Bool?
    var workspaces: [Workspace]
    var pollInterval: Int?
    var socketFound: Bool?
    var connected: Bool?
    var staleData: Bool?
    var model: String?
    var reviewEnabled: Bool?
    var reviewModel: String?
    var reviewBackend: String?
    var contractReviewEnabled: Bool?
    var approvalThreshold: Int?
    var ollamaAvailable: Bool?
}

struct Workspace: Codable, Identifiable, Hashable {
    var hasClaude: Bool?
    var index: Int
    var name: String
    var uuid: String
    var enabled: Bool?
    var autoMode: WorkspaceAutoMode?
    var starred: Bool?
    var customName: String?
    var lastCheck: String?
    var screenTail: String?
    var screenFull: String?
    var cwd: String?
    var branch: String?
    var sessionCost: String?
    var surfaceId: String?
    var surfaceLabel: String?
    var surfaceTitle: String?
    var gitDirty: Bool?
    var surfaceAge: Double?

    var id: String {
        if !uuid.isEmpty {
            return surfaceId.map { "\(uuid)|\($0)" } ?? uuid
        }
        return String(index)
    }

    var displayName: String {
        let custom = customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty { return custom }
        let label = surfaceLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !label.isEmpty { return label }
        return name
    }

    var resolvedAutoMode: WorkspaceAutoMode {
        autoMode ?? ((enabled ?? false) ? .auto : .off)
    }
}

struct ScreenResponse: Codable {
    var ok: Bool
    var screen: String
    var lines: Int?
    var error: String?
}

struct BasicResponse: Codable {
    var ok: Bool
    var enabled: Bool?
    var error: String?
}

struct NewSessionResponse: Codable {
    struct CreatedWorkspace: Codable {
        var index: Int?
        var uuid: String?
    }

    var ok: Bool
    var workspace: CreatedWorkspace?
    var worktreePath: String?
    var branchName: String?
    var error: String?
}

struct AttachmentUploadResponse: Codable {
    var ok: Bool
    var attachment: UploadedAttachment?
    var error: String?
}

struct UploadedAttachment: Codable, Hashable {
    var id: String?
    var filename: String?
    var path: String?
    var url: String?
    var contentType: String?
    var size: Int?
}

struct TerminalAttachment: Identifiable, Hashable {
    enum State: Hashable {
        case pending
        case uploading
        case uploaded
        case failed(String)

        var label: String {
            switch self {
            case .pending:
                "Pending"
            case .uploading:
                "Uploading"
            case .uploaded:
                "Uploaded"
            case .failed:
                "Failed"
            }
        }
    }

    var id = UUID()
    var sourceURL: URL
    var filename: String
    var state: State = .pending
    var uploaded: UploadedAttachment?
}

enum DiscoveredHarnessServerSource: String, Equatable, Sendable {
    case tailscale
    case lan
}

struct DiscoveredHarnessServer: Equatable, Identifiable, Sendable {
    var name: String
    var urlString: String
    var source: DiscoveredHarnessServerSource

    var id: String { urlString }
}

struct FeedResponse: Codable {
    var ok: Bool
    var items: [FeedItem]
    var error: String?
}

struct FeedItem: Codable, Identifiable, Hashable {
    var requestID: String
    var kind: String
    var title: String?
    var message: String?
    var command: String?
    var workspaceID: String?
    var surfaceID: String?
    var agent: String?
    var createdAt: String?
    var options: [String]?

    var id: String { requestID }

    var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        switch kind {
        case "permission":
            return "Permission Request"
        case "plan":
            return "Plan Approval"
        case "question":
            return "Question"
        default:
            return "cmux Feed"
        }
    }

    var summary: String {
        let messageText = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !messageText.isEmpty { return messageText }
        return command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? displayTitle
    }
}

struct LogEntry: Codable, Identifiable, Hashable {
    var timestamp: String?
    var workspace: Int?
    var workspaceName: String?
    var promptType: String?
    var action: String?
    var reason: String?
    var key: String?
    var surfaceId: String?

    var id: String {
        [timestamp, workspaceName, action, reason]
            .compactMap { $0 }
            .joined(separator: "|")
    }
}

struct GitStatus: Codable {
    var ok: Bool?
    var branch: String?
    var cwd: String?
    var staged: [GitFile]?
    var unstaged: [GitFile]?
    var untracked: [String]?
    var commits: [GitCommit]?
    var error: String?
}

struct GitFile: Codable, Identifiable, Hashable {
    var status: String
    var file: String

    var id: String { "\(status):\(file)" }
}

struct GitCommit: Codable, Identifiable, Hashable {
    var hash: String
    var message: String

    var id: String { hash }
}

struct GitDiffResponse: Codable {
    var ok: Bool
    var diff: String
    var error: String?
}

struct GitHubPRCommentsResponse: Codable {
    var ok: Bool
    var threads: [GitHubPRThread]?
    var error: String?
}

struct GitHubPRThread: Codable, Identifiable, Hashable {
    var id: String
    var path: String?
    var line: Int?
    var isResolved: Bool?
    var isOutdated: Bool?
    var url: String?
    var comments: [GitHubPRComment]?
}

struct GitHubPRComment: Codable, Identifiable, Hashable {
    var id: String
    var author: String?
    var bodyText: String?
    var createdAt: String?
    var url: String?
}

struct JiraTicketsResponse: Codable {
    var ok: Bool
    var tickets: [JiraTicket]?
    var issues: [JiraTicket]?
    var error: String?

    var resolvedTickets: [JiraTicket] { tickets ?? issues ?? [] }
}

struct JiraTicketResponse: Codable {
    var ok: Bool
    var ticket: JiraTicket?
    var issue: JiraTicket?
    var error: String?

    var resolvedTicket: JiraTicket? { ticket ?? issue }
}

struct JiraTicket: Codable, Identifiable, Hashable {
    var key: String
    var summary: String?
    var status: String?
    var url: String?

    var id: String { key }
}

struct FileSearchResponse: Codable {
    var ok: Bool
    var matches: [ProjectFileMatch]?
    var results: [ProjectFileMatch]?
    var error: String?

    var resolvedMatches: [ProjectFileMatch] { matches ?? results ?? [] }
}

struct ProjectFileMatch: Codable, Identifiable, Hashable {
    var path: String
    var score: Double?
    var line: Int?
    var preview: String?

    var id: String { "\(path):\(line ?? 0)" }
}

struct SkillsResponse: Codable {
    var ok: Bool
    var projectSkills: [ProjectSkill]?
    var userSkills: [ProjectSkill]?
    var error: String?
}

struct ProjectSkill: Codable, Identifiable, Hashable {
    var name: String
    var path: String?
    var description: String?

    var id: String { path ?? name }
}

struct NetworkResponse: Codable {
    var ok: Bool
    var port: Int?
    var hostname: String?
    var localName: String?
    var urls: NetworkURLs?
}

struct NetworkURLs: Codable {
    var home: String?
    var harness: String?
    var localHarness: String?
    var lanHarness: [String]?
    var tailscaleHarness: String?
    var detectedTailscaleHarness: String?
    var tailscaleIpHarness: String?
}
