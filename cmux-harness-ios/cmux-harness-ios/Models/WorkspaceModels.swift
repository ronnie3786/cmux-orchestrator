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
