import Foundation

/// Pure projection for the identity-bearing session chips shown alongside the
/// collapsed HUD orb. The pi-chat gate stays shared with HUD notifications,
/// while mute and dismissal remain local to this surface.
enum HerdrHudSessionChips {
    struct Chip: Identifiable, Equatable {
        let id: String
        let title: String
        let status: AgentStatus
        let isMuted: Bool
        let since: Date?
    }

    static func chips(
        panes: [HerdrPane],
        mutedPaneIDs: Set<String>,
        dismissedStatuses: [String: AgentStatus],
        revealTitles: Bool,
        limit: Int = HerdrHudPlacement.maxChips
    ) -> (chips: [Chip], overflow: Int) {
        let candidates = HerdrHudNotificationFilter.panes(panes)
            .filter { pane in
                switch pane.agentStatus {
                case .blocked, .done, .working:
                    true
                case .idle, .unknown:
                    false
                }
            }
            .filter { dismissedStatuses[$0.id] != $0.agentStatus }
            .filter { pane in
                !(mutedPaneIDs.contains(pane.id) && pane.agentStatus != .blocked)
            }
            .sorted { left, right in
                if left.agentStatus.attentionRank != right.agentStatus.attentionRank {
                    return left.agentStatus.attentionRank < right.agentStatus.attentionRank
                }
                let leftSince = since(for: left)
                let rightSince = since(for: right)
                switch (leftSince, rightSince) {
                case let (leftDate?, rightDate?):
                    if leftDate != rightDate { return leftDate > rightDate }
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    break
                }
                if left.revision != right.revision { return left.revision > right.revision }
                return left.id < right.id
            }

        let chipLimit = max(0, limit)
        let visibleCandidates = candidates.prefix(chipLimit)
        let result = visibleCandidates.enumerated().map { index, pane in
            Chip(
                id: pane.id,
                title: revealTitles ? pane.displayTitle : "session \(index + 1)",
                status: pane.agentStatus,
                isMuted: mutedPaneIDs.contains(pane.id) && pane.agentStatus == .blocked,
                since: since(for: pane)
            )
        }
        return (Array(result), max(0, candidates.count - chipLimit))
    }

    private static func since(for pane: HerdrPane) -> Date? {
        pane.agentStatus == .working ? pane.workingSince : pane.lastActivityAt
    }
}
