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
        let artifacts: [AgentResultArtifact]

        init(
            id: String,
            title: String,
            status: AgentStatus,
            isMuted: Bool,
            since: Date?,
            artifacts: [AgentResultArtifact] = []
        ) {
            self.id = id
            self.title = title
            self.status = status
            self.isMuted = isMuted
            self.since = since
            self.artifacts = artifacts
        }
    }

    static func chips(
        panes: [HerdrPane],
        mutedPaneIDs: Set<String>,
        dismissedStatuses: [String: AgentStatus],
        revealTitles: Bool,
        artifacts: [AgentResultArtifact] = [],
        limit: Int = HerdrHudPlacement.maxChips
    ) -> (chips: [Chip], overflow: Int, detachedArtifacts: [AgentResultArtifact]) {
        let paneArtifacts = Dictionary(grouping: artifacts.filter { $0.originType == .pane }) { artifact in
            MachineScopedID.compose(machineID: artifact.machineID, rawID: artifact.originID)
        }
        let candidates = HerdrHudNotificationFilter.panes(panes)
            .filter { pane in
                switch pane.agentStatus {
                case .blocked, .done, .working:
                    true
                case .idle, .unknown:
                    !(paneArtifacts[pane.id] ?? []).isEmpty
                }
            }
            .filter { pane in
                dismissedStatuses[pane.id] != pane.agentStatus || !(paneArtifacts[pane.id] ?? []).isEmpty
            }
            .filter { pane in
                !(mutedPaneIDs.contains(pane.id)
                    && pane.agentStatus != .blocked
                    && (paneArtifacts[pane.id] ?? []).isEmpty)
            }
            .sorted { left, right in
                let leftHasResults = !(paneArtifacts[left.id] ?? []).isEmpty
                let rightHasResults = !(paneArtifacts[right.id] ?? []).isEmpty
                if left.agentStatus != .blocked, right.agentStatus != .blocked,
                   leftHasResults != rightHasResults {
                    return leftHasResults
                }
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
                since: since(for: pane),
                artifacts: sortedArtifacts(paneArtifacts[pane.id] ?? [])
            )
        }
        // Results belonging to a chip folded under `+N` dock to the orb until
        // that chip is revealed. An unviewed result is therefore always on the
        // visible HUD, never hidden merely because its session overflowed.
        let attachedArtifactIDs = Set(visibleCandidates.flatMap { paneArtifacts[$0.id] ?? [] }.map(\.id))
        let detachedArtifacts = artifacts.filter { !attachedArtifactIDs.contains($0.id) }
        return (
            Array(result),
            max(0, candidates.count - chipLimit),
            sortedArtifacts(detachedArtifacts)
        )
    }

    /// Drops a dismissal as soon as its pane leaves the status it was dismissed
    /// at, so a dismissal silences one *episode* rather than the status value
    /// forever. Without this, clicking a finished session's chip once retired
    /// every later `.done` for that pane and completed agents quietly stopped
    /// appearing on the HUD. Entries for panes that vanished are dropped too.
    static func prunedDismissals(
        _ dismissed: [String: AgentStatus],
        machineID: String,
        panes: [HerdrPane]
    ) -> [String: AgentStatus] {
        var liveStatuses: [String: AgentStatus] = [:]
        for pane in panes {
            liveStatuses[pane.id] = pane.agentStatus
        }
        return dismissed.filter { paneID, dismissedStatus in
            guard MachineScopedID.split(paneID)?.machineID == machineID else { return true }
            guard let status = liveStatuses[paneID] else { return false }
            return status == dismissedStatus
        }
    }

    private static func since(for pane: HerdrPane) -> Date? {
        pane.agentStatus == .working ? pane.workingSince : pane.lastActivityAt
    }

    private static func sortedArtifacts(_ artifacts: [AgentResultArtifact]) -> [AgentResultArtifact] {
        artifacts.sorted { left, right in
            let leftDate = left.createdDate ?? .distantPast
            let rightDate = right.createdDate ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            return left.id > right.id
        }
    }
}
