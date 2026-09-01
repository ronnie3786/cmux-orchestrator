import Foundation

/// Pure projection for the bounded Herd Pulse session list.
enum HerdPulseSessions {
    private struct Candidate {
        let pane: HerdrPane
        let newestAlertDate: Date?
    }

    static func sessions(
        panes: [HerdrPane],
        alerts: [HerdrAlert],
        pendingReadPaneIDs: Set<String> = [],
        revealTitles: Bool,
        limit: Int = 6,
        now: Date = .now
    ) -> (sessions: [HerdPulseAttributes.ContentState.Session], overflow: Int) {
        _ = now
        let panesByID = Dictionary(uniqueKeysWithValues: panes.map { ($0.id, $0) })
        var newestAlertDates: [String: Date] = [:]
        for alert in alerts {
            let paneID = alert.scopedPaneID
            guard let createdDate = alert.createdDate,
                  let pane = panesByID[paneID],
                  alert.status == pane.agentStatus
            else { continue }
            newestAlertDates[paneID] = max(newestAlertDates[paneID] ?? .distantPast, createdDate)
        }

        let candidates = panes.compactMap { pane -> Candidate? in
            guard pane.agentStatus == .blocked || pane.agentStatus == .done || pane.agentStatus == .working else {
                return nil
            }
            guard !(pane.agentStatus == .done && pendingReadPaneIDs.contains(pane.id)) else {
                return nil
            }
            return Candidate(pane: pane, newestAlertDate: newestAlertDates[pane.id])
        }
        .sorted { left, right in
            let leftRank = left.pane.agentStatus.attentionRank
            let rightRank = right.pane.agentStatus.attentionRank
            if leftRank != rightRank { return leftRank < rightRank }

            if left.pane.agentStatus == .working {
                switch (left.pane.workingSince, right.pane.workingSince) {
                case let (leftDate?, rightDate?) where leftDate != rightDate:
                    return leftDate < rightDate
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                default:
                    break
                }
            } else {
                switch (left.newestAlertDate, right.newestAlertDate) {
                case let (leftDate?, rightDate?) where leftDate != rightDate:
                    return leftDate > rightDate
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                default:
                    break
                }
            }

            if left.pane.revision != right.pane.revision { return left.pane.revision > right.pane.revision }
            return left.pane.id < right.pane.id
        }

        let rowLimit = max(0, limit)
        let rows = candidates.prefix(rowLimit).enumerated().map { index, candidate in
            let pane = candidate.pane
            return if revealTitles {
                HerdPulseAttributes.ContentState.Session(
                    id: pane.id,
                    title: String(pane.displayTitle.prefix(40)),
                    agent: String(pane.displayAgentName.prefix(16)),
                    state: sessionState(for: pane.agentStatus),
                    since: since(for: candidate)
                )
            } else {
                HerdPulseAttributes.ContentState.Session(
                    id: "s\(index + 1)",
                    title: "session \(index + 1)",
                    agent: "",
                    state: sessionState(for: pane.agentStatus),
                    since: since(for: candidate)
                )
            }
        }
        return (Array(rows), max(0, candidates.count - rowLimit))
    }

    private static func sessionState(for status: AgentStatus) -> HerdPulseSessionState {
        switch status {
        case .blocked: .blocked
        case .done: .done
        case .working: .working
        case .idle, .unknown:
            preconditionFailure("Only blocked, done, and working panes are candidates")
        }
    }

    private static func since(for candidate: Candidate) -> Int {
        let date: Date?
        if candidate.pane.agentStatus == .working {
            date = candidate.pane.workingSince
        } else {
            date = candidate.newestAlertDate ?? candidate.pane.lastActivityAt
        }
        return date.map { Int($0.timeIntervalSince1970) } ?? 0
    }
}
