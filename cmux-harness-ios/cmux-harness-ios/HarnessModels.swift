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
    var autoMode: WorkspaceAutoMode?
    var starred = false
    var autoEnabledAt: Double?
    var autoExpiresAt: Double?
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
        // Single-surface refs can appear or change as cmux metadata warms.
        // Multi-surface rows need the surface ref to remain distinct.
        if surfaceLabel != nil, let surfaceId, !surfaceId.isEmpty {
            return [stableID, surfaceId].joined(separator: "|")
        }
        return stableID
    }

    var displayName: String {
        let hasCustomName = customName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let rawValue = surfaceLabel ?? customName ?? name
        let value = rawValue.isEmpty ? "workspace-\(index)" : rawValue
        return hasCustomName ? value : Self.shortenedFallbackTitle(value)
    }

    var terminalPreview: String {
        let text = screenTail ?? screenFull ?? ""
        return text.isEmpty ? "(no terminal data yet)" : text
    }

    var resolvedAutoMode: WorkspaceAutoMode {
        autoMode ?? (enabled ? .auto : .off)
    }

    private static func shortenedFallbackTitle(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let separator = " : "
        if let range = trimmed.range(of: separator) {
            let leading = String(trimmed[..<range.lowerBound])
            let trailing = String(trimmed[range.upperBound...])
            return pathBasename(leading) + separator + trailing
        }
        return pathBasename(trimmed)
    }

    private static func pathBasename(_ value: String) -> String {
        let normalized = value.replacingOccurrences(of: "\\", with: "/")
        let components = normalized
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        return components.last ?? value
    }
}

enum WorkspaceAutoMode: String, Codable, CaseIterable, Equatable, Identifiable, Sendable {
    case off
    case auto
    case superAuto = "super"

    var id: String { rawValue }

    var isEnabled: Bool {
        self != .off
    }

    var label: String {
        switch self {
        case .off:
            return "Off"
        case .auto:
            return "Auto"
        case .superAuto:
            return "Super"
        }
    }

    var menuLabel: String {
        switch self {
        case .off:
            return "Off"
        case .auto:
            return "Auto"
        case .superAuto:
            return "Super Auto"
        }
    }

    var systemImage: String {
        switch self {
        case .off:
            return "circle"
        case .auto:
            return "bolt.fill"
        case .superAuto:
            return "bolt.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .off:
            return "Auto disabled"
        case .auto:
            return "Auto enabled"
        case .superAuto:
            return "Super auto enabled"
        }
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

struct SkillsResponse: Decodable, Equatable, Sendable {
    var ok: Bool
    var rootPath: String?
    var skillsDirectory: String?
    var userSkillsDirectory: String? = nil
    var projectSkills: [ProjectSkill]? = nil
    var userSkills: [ProjectSkill]? = nil
    var skills: [ProjectSkill]? = nil
    var error: String?

    var resolvedProjectSkills: [ProjectSkill] {
        projectSkills ?? skills?.filter { $0.scope == "project" } ?? []
    }

    var resolvedUserSkills: [ProjectSkill] {
        userSkills ?? skills?.filter { $0.scope == "user" } ?? []
    }
}

struct ProjectSkill: Decodable, Equatable, Identifiable, Sendable {
    var name: String
    var skillFilePath: String
    var scope: String? = nil

    var id: String { "\(scope ?? "project")|\(name)" }
}

struct FileSearchResponse: Decodable, Equatable, Sendable {
    var ok: Bool
    var rootPath: String?
    var query: String
    var files: [ProjectFileMatch]
    var truncated: Bool?
    var limit: Int?
    var error: String?
}

struct ProjectFileMatch: Decodable, Equatable, Identifiable, Sendable {
    var path: String

    var id: String { path }
}

struct JiraTicketsResponse: Decodable, Equatable, Sendable {
    var ok: Bool
    var project: String?
    var site: String?
    var tickets: [JiraTicket]
    var error: String?
}

struct JiraTicket: Decodable, Equatable, Identifiable, Sendable {
    var key: String
    var title: String
    var status: String
    var priority: String
    var issueType: String
    var url: String

    var id: String { key }
}

struct AttachmentUploadResponse: Decodable, Equatable, Sendable {
    var ok: Bool
    var attachment: UploadedAttachment?
    var error: String?
}

struct UploadedAttachment: Decodable, Equatable, Identifiable, Sendable {
    var id: String
    var filename: String
    var originalFilename: String
    var contentType: String
    var size: Int
    var path: String
    var workspaceKey: String
    var createdAt: String
}

struct TerminalAttachment: Equatable, Identifiable, Sendable {
    var id: UUID
    var filename: String
    var sourceURL: URL
    var status: TerminalAttachmentStatus
    var uploaded: UploadedAttachment?
    var error: String?

    var displayName: String {
        let original = uploaded?.originalFilename.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return original.isEmpty ? filename : original
    }

    var uploadedPath: String? {
        let value = uploaded?.path.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}

enum TerminalAttachmentStatus: String, Equatable, Sendable {
    case uploading
    case uploaded
    case failed
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
    case session
    case waiting

    var label: String {
        switch self {
        case .session:
            return "Session"
        case .waiting:
            return "Needs You"
        }
    }
}

enum SessionFilter: String, CaseIterable, Equatable, Identifiable, Sendable {
    case all
    case needsYou
    case auto

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:
            return "All"
        case .needsYou:
            return "Needs You"
        case .auto:
            return "Auto"
        }
    }

    func includes(_ workspace: Workspace, entries: [LogEntry]) -> Bool {
        switch self {
        case .all:
            return true
        case .needsYou:
            return workspaceSessionState(for: workspace, entries: entries) == .waiting
        case .auto:
            return workspace.resolvedAutoMode.isEnabled
        }
    }
}

extension Workspace {
    func matchesSearch(_ searchText: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }

        return [
            displayName,
            name,
            customName,
            cwd,
            branch,
            surfaceLabel,
            surfaceTitle,
        ]
        .compactMap { $0 }
        .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

func workspaceSessionState(for workspace: Workspace, entries: [LogEntry]) -> WorkspaceSessionState {
    if let action = latestRelevantLog(for: workspace, entries: entries)?.action,
       action.localizedCaseInsensitiveContains("human") {
        return .waiting
    }
    return .session
}

func latestRelevantLog(for workspace: Workspace, entries: [LogEntry]) -> LogEntry? {
    entries.enumerated()
        .filter { _, entry in entry.workspace == workspace.index }
        .sorted { lhs, rhs in
            let leftDate = harnessLogDate(from: lhs.element.timestamp)
            let rightDate = harnessLogDate(from: rhs.element.timestamp)
            switch (leftDate, rightDate) {
            case let (left?, right?) where left != right:
                return left > right
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            default:
                return lhs.offset < rhs.offset
            }
        }
        .first?
        .element
}

private func harnessLogDate(from value: String?) -> Date? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let seconds = TimeInterval(trimmed) {
        return Date(timeIntervalSince1970: seconds)
    }

    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractionalFormatter.date(from: trimmed) {
        return date
    }

    return ISO8601DateFormatter().date(from: trimmed)
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
