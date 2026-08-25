import Foundation

/// Pure, unit-testable projection powering Herd Pulse's attention session rows.
/// It remains separate from `HerdPulseMenuBarPresentation` because it accepts
/// identity-bearing input and redacts it when session titles are hidden.
enum HerdPulseAttentionRows {
    struct Row: Identifiable, Equatable {
        let id: String
        let title: String
        let subtitle: String
        let status: AgentStatus
    }

    private struct Candidate {
        let pane: HerdrPane
        let attentionRank: Int
        let alertCreatedAt: String?
        let revision: Int
    }

    static func attentionRows(
        panes: [HerdrPane],
        alerts: [HerdrAlert],
        revealTitles: Bool,
        limit: Int = 5
    ) -> (rows: [Row], overflow: Int) {
        var newestAlertDates: [String: String] = [:]
        for alert in alerts {
            let paneID = alert.scopedPaneID
            if let existing = newestAlertDates[paneID] {
                if alert.createdAt > existing {
                    newestAlertDates[paneID] = alert.createdAt
                }
            } else {
                newestAlertDates[paneID] = alert.createdAt
            }
        }

        var candidates: [Candidate] = []
        for pane in panes {
            candidates.append(
                Candidate(
                    pane: pane,
                    attentionRank: pane.agentStatus.attentionRank,
                    alertCreatedAt: newestAlertDates[pane.id],
                    revision: pane.revision
                )
            )
        }
        candidates.sort {
            if $0.attentionRank != $1.attentionRank {
                return $0.attentionRank < $1.attentionRank
            }
            switch ($0.alertCreatedAt, $1.alertCreatedAt) {
            case let (left?, right?):
                if left != right { return left > right }
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                break
            }
            return $0.revision > $1.revision
        }

        let rowLimit = max(0, limit)
        var rows: [Row] = []
        for (index, candidate) in candidates.enumerated() {
            guard index < rowLimit else { break }
            let statusWord = statusWord(for: candidate.pane.agentStatus)
            if revealTitles {
                rows.append(
                    Row(
                        id: candidate.pane.id,
                        title: candidate.pane.displayTitle,
                        subtitle: "\(candidate.pane.displayAgentName) · \(statusWord)",
                        status: candidate.pane.agentStatus
                    )
                )
            } else {
                rows.append(
                    Row(
                        id: candidate.pane.id,
                        title: "session \(index + 1)",
                        subtitle: statusWord,
                        status: candidate.pane.agentStatus
                    )
                )
            }
        }

        return (rows, max(0, candidates.count - rowLimit))
    }

    private static func statusWord(for status: AgentStatus) -> String {
        switch status {
        case .blocked:
            "needs you"
        case .done:
            "ready"
        default:
            status.title.lowercased()
        }
    }
}
