import Foundation

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
