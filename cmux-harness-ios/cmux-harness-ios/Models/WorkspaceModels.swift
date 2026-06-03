import Foundation

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

    var sessionGroupID: String {
        let trimmedUUID = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedUUID.isEmpty ? id : trimmedUUID
    }

    var displayName: String {
        let hasCustomName = customName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let rawValue = surfaceLabel ?? customName ?? name
        let value = rawValue.isEmpty ? "workspace-\(index)" : rawValue
        return hasCustomName ? value : Self.shortenedFallbackTitle(value)
    }

    var sessionDisplayName: String {
        let hasCustomName = customName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let rawValue = customName ?? name
        let value = rawValue.isEmpty ? "workspace-\(index)" : rawValue
        return hasCustomName ? value : Self.shortenedFallbackTitle(value)
    }

    var paneDisplayName: String {
        if let surfaceLabel = surfaceLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !surfaceLabel.isEmpty {
            let separator = " : "
            if let range = surfaceLabel.range(of: separator) {
                let trailing = String(surfaceLabel[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !trailing.isEmpty {
                    return trailing
                }
            }
            return surfaceLabel
        }
        if let surfaceTitle = surfaceTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !surfaceTitle.isEmpty {
            return surfaceTitle
        }
        return "Pane"
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

struct WorkspaceSessionGroup: Equatable, Identifiable, Sendable {
    var id: String
    var workspaces: [Workspace]

    init?(workspaces: [Workspace]) {
        let sortedWorkspaces = workspaces.sorted(by: Self.sortPanes)
        guard let firstWorkspace = sortedWorkspaces.first else { return nil }
        self.id = firstWorkspace.sessionGroupID
        self.workspaces = sortedWorkspaces
    }

    var primaryWorkspace: Workspace {
        workspaces[0]
    }

    var displayName: String {
        primaryWorkspace.sessionDisplayName
    }

    var paneCount: Int {
        workspaces.count
    }

    var hasMultiplePanes: Bool {
        paneCount > 1
    }

    func containsWorkspace(id workspaceID: String?) -> Bool {
        guard let workspaceID else { return false }
        return workspaces.contains { $0.id == workspaceID }
    }

    func preferredWorkspaceID(selectedWorkspaceID: String?) -> String {
        if containsWorkspace(id: selectedWorkspaceID), let selectedWorkspaceID {
            return selectedWorkspaceID
        }
        return primaryWorkspace.id
    }

    func paneLabel(for workspace: Workspace, offset: Int) -> String {
        let label = workspace.paneDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return label == "Pane" || label.isEmpty ? "Pane \(offset + 1)" : label
    }

    func matchesSearch(_ searchText: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        if displayName.localizedCaseInsensitiveContains(query) {
            return true
        }
        return workspaces.contains {
            $0.matchesSearch(query) || $0.paneDisplayName.localizedCaseInsensitiveContains(query)
        }
    }

    static func groups(from workspaces: [Workspace]) -> [WorkspaceSessionGroup] {
        Dictionary(grouping: workspaces, by: \.sessionGroupID)
            .values
            .compactMap(WorkspaceSessionGroup.init(workspaces:))
            .sorted(by: sortGroups)
    }

    private static func sortPanes(_ lhs: Workspace, _ rhs: Workspace) -> Bool {
        if lhs.index != rhs.index {
            return lhs.index < rhs.index
        }
        let titleOrder = lhs.paneDisplayName.localizedCaseInsensitiveCompare(rhs.paneDisplayName)
        if titleOrder != .orderedSame {
            return titleOrder == .orderedAscending
        }
        return lhs.id < rhs.id
    }

    private static func sortGroups(_ lhs: WorkspaceSessionGroup, _ rhs: WorkspaceSessionGroup) -> Bool {
        let left = lhs.primaryWorkspace
        let right = rhs.primaryWorkspace
        if left.starred != right.starred {
            return left.starred && !right.starred
        }
        let displayOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if displayOrder != .orderedSame {
            return displayOrder == .orderedAscending
        }
        let idOrder = lhs.id.localizedCaseInsensitiveCompare(rhs.id)
        if idOrder != .orderedSame {
            return idOrder == .orderedAscending
        }
        return left.index < right.index
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
