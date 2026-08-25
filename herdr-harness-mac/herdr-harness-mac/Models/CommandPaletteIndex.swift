import Foundation

/// Builds and searches the pane index behind the global ⌘K palette.
///
/// Match quality wins first (exact, prefix, word prefix, substring, fuzzy
/// subsequence), then field priority (title, agent, workspace, tab, machine,
/// path). The original fleet order is the final tie-breaker, so results never
/// jump around between identical queries.
enum CommandPaletteIndex {
    static func entries(
        workspaces: [HerdrWorkspace],
        machines: [HerdrMachine]
    ) -> [CommandPaletteEntry] {
        let machineByID = Dictionary(uniqueKeysWithValues: machines.map { ($0.id, $0) })
        let machineOrder = Dictionary(uniqueKeysWithValues: machines.enumerated().map { ($0.element.id, $0.offset) })
        let sortedWorkspaces = workspaces.sorted { lhs, rhs in
            let lhsMachineOrder = machineOrder[lhs.machineID] ?? Int.max
            let rhsMachineOrder = machineOrder[rhs.machineID] ?? Int.max
            if lhsMachineOrder != rhsMachineOrder { return lhsMachineOrder < rhsMachineOrder }
            if lhs.number != rhs.number { return lhs.number < rhs.number }
            return lhs.id < rhs.id
        }

        var result: [CommandPaletteEntry] = []
        result.reserveCapacity(sortedWorkspaces.reduce(0) { $0 + $1.panes.count })

        for workspace in sortedWorkspaces {
            var tabsByID: [String: HerdrTab] = [:]
            for tab in workspace.tabs {
                tabsByID[tab.id] = tab
                tabsByID[tab.tabID] = tab
            }
            let sortedPanes = workspace.panes.sorted { lhs, rhs in
                let lhsTab = tabsByID[lhs.scopedTabID] ?? tabsByID[lhs.tabID]
                let rhsTab = tabsByID[rhs.scopedTabID] ?? tabsByID[rhs.tabID]
                let lhsTabNumber = lhsTab?.number ?? Int.max
                let rhsTabNumber = rhsTab?.number ?? Int.max
                if lhsTabNumber != rhsTabNumber { return lhsTabNumber < rhsTabNumber }
                return lhs.paneID < rhs.paneID
            }

            for pane in sortedPanes {
                let tab = tabsByID[pane.scopedTabID] ?? tabsByID[pane.tabID]
                let machineName = machineByID[workspace.machineID]?.name
                    ?? (workspace.machineID.isEmpty ? machines.first?.name : workspace.machineID)
                    ?? "This Mac"
                result.append(CommandPaletteEntry(
                    paneID: pane.id,
                    title: pane.displayTitle,
                    agentName: pane.displayAgentName,
                    workspaceName: workspace.label,
                    workspacePath: workspace.displayPath,
                    tabName: tab?.label ?? "",
                    machineName: machineName,
                    status: pane.agentStatus,
                    order: result.count
                ))
            }
        }
        return result
    }

    static func search(
        _ entries: [CommandPaletteEntry],
        query: String
    ) -> [CommandPaletteEntry] {
        let tokens = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return entries.sorted { $0.order < $1.order } }

        return entries.compactMap { entry -> (entry: CommandPaletteEntry, score: Int)? in
            guard let score = score(entry, tokens: tokens) else { return nil }
            return (entry, score)
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            return lhs.entry.order < rhs.entry.order
        }
        .map(\.entry)
    }

    private static func score(_ entry: CommandPaletteEntry, tokens: [String]) -> Int? {
        let fields: [(value: String, priority: Int)] = [
            (entry.title, 0),
            (entry.agentName, 8),
            (entry.workspaceName, 16),
            (entry.tabName, 24),
            (entry.machineName, 32),
            (entry.workspacePath, 40),
        ]
        var total = 0
        for token in tokens {
            let candidateScores = fields.compactMap { field in
                matchScore(token: token, candidate: field.value).map { $0 + field.priority }
            }
            guard let best = candidateScores.min() else { return nil }
            total += best
        }
        return total
    }

    private static func matchScore(token: String, candidate: String) -> Int? {
        guard !candidate.isEmpty else { return nil }
        let foldedToken = folded(token)
        let foldedCandidate = folded(candidate)
        guard !foldedToken.isEmpty else { return nil }

        if foldedCandidate == foldedToken { return 0 }
        if foldedCandidate.hasPrefix(foldedToken) { return 100 }
        if foldedCandidate
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .contains(where: { $0.hasPrefix(foldedToken) }) {
            return 200
        }
        if candidate.localizedStandardContains(token) { return 300 }
        if let penalty = subsequencePenalty(needle: foldedToken, haystack: foldedCandidate) {
            return 400 + min(penalty, 99)
        }
        return nil
    }

    private static func folded(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .autoupdatingCurrent)
    }

    private static func subsequencePenalty(needle: String, haystack: String) -> Int? {
        let needleCharacters = Array(needle)
        let haystackCharacters = Array(haystack)
        guard !needleCharacters.isEmpty else { return 0 }

        var haystackIndex = 0
        var firstMatch: Int?
        var lastMatch = 0
        for character in needleCharacters {
            var found: Int?
            while haystackIndex < haystackCharacters.count {
                if haystackCharacters[haystackIndex] == character {
                    found = haystackIndex
                    haystackIndex += 1
                    break
                }
                haystackIndex += 1
            }
            guard let found else { return nil }
            if firstMatch == nil { firstMatch = found }
            lastMatch = found
        }

        let span = lastMatch - (firstMatch ?? 0) + 1
        return (firstMatch ?? 0) + max(0, span - needleCharacters.count)
    }
}
