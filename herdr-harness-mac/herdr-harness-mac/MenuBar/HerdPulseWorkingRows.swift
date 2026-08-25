import Foundation

/// Identity-bearing projection for the working sessions shown inside Herd Pulse.
/// The counts-only `HerdPulseContentState` deliberately remains unchanged.
enum HerdPulseWorkingRows {
    struct Row: Identifiable, Equatable {
        let id: String
        let title: String
        let subtitle: String
        let since: Date?
    }

    static func workingRows(
        panes: [HerdrPane],
        revealTitles: Bool,
        limit: Int = 4
    ) -> (rows: [Row], overflow: Int) {
        let candidates = panes
            .filter { $0.agentStatus == .working }
            .sorted { left, right in
                switch (left.workingSince, right.workingSince) {
                case let (leftDate?, rightDate?):
                    if leftDate != rightDate { return leftDate < rightDate }
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

        let rowLimit = max(0, limit)
        let rows = candidates.prefix(rowLimit).enumerated().map { index, pane in
            if revealTitles {
                Row(
                    id: pane.id,
                    title: pane.displayTitle,
                    subtitle: "\(pane.displayAgentName) · working",
                    since: pane.workingSince
                )
            } else {
                Row(
                    id: pane.id,
                    title: "working session \(index + 1)",
                    subtitle: "working",
                    since: pane.workingSince
                )
            }
        }

        return (Array(rows), max(0, candidates.count - rowLimit))
    }
}
