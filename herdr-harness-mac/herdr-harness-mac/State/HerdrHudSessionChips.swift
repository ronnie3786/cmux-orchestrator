import Foundation

/// One dismissal of one session chip, keyed to the *episode* it silenced.
///
/// Status alone cannot express "the thing I dismissed": a pane reads `.done`
/// both before and after it answers again, so a status-only key is unsafe to
/// persist — yesterday's dismissal would silence today's answer.
struct HudChipDismissal: Codable, Equatable, Sendable {
    let status: AgentStatus
    /// `HerdrPane.episodeKey` at the moment of dismissal.
    let episode: String
    /// Only used to cap the persisted store newest-first; the projection
    /// deliberately ignores it.
    let dismissedAt: Date

    init(status: AgentStatus, episode: String, dismissedAt: Date) {
        self.status = status
        self.episode = episode
        self.dismissedAt = dismissedAt
    }

    init(pane: HerdrPane, dismissedAt: Date) {
        self.init(status: pane.agentStatus, episode: pane.episodeKey, dismissedAt: dismissedAt)
    }

    func silences(_ pane: HerdrPane) -> Bool {
        status == pane.agentStatus && episode == pane.episodeKey
    }
}

/// Pure projection for the identity-bearing session chips shown alongside the
/// collapsed HUD orb. The pi-chat gate stays shared with HUD notifications,
/// while mute and dismissal remain local to this surface.
///
/// **Artifacts never create or resurrect a session chip.** They attach to a
/// chip that is independently visible, and otherwise dock to the orb via
/// `detachedArtifacts`. An unviewed result is still always reachable from the
/// collapsed HUD — but it can no longer defeat a dismissal or a mute, which is
/// what used to make a clicked session reappear forever: clicking the chip
/// routes to the pane, the harness acks it to `.idle`, and the artifact clause
/// put the chip straight back on the next projection.
enum HerdrHudSessionChips {
    struct Chip: Identifiable, Equatable {
        let id: String
        let title: String
        let status: AgentStatus
        let isMuted: Bool
        let since: Date?
        let artifacts: [AgentResultArtifact]
        let voiceNoteID: String?
        let detail: String?
        let symbol: String?

        init(
            id: String,
            title: String,
            status: AgentStatus,
            isMuted: Bool,
            since: Date?,
            artifacts: [AgentResultArtifact] = [],
            voiceNoteID: String? = nil,
            detail: String? = nil,
            symbol: String? = nil
        ) {
            self.id = id
            self.title = title
            self.status = status
            self.isMuted = isMuted
            self.since = since
            self.artifacts = artifacts
            self.voiceNoteID = voiceNoteID
            self.detail = detail
            self.symbol = symbol
        }
    }

    static func chips(
        panes: [HerdrPane],
        mutedPaneIDs: Set<String>,
        dismissed: [String: HudChipDismissal],
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
                    false
                }
            }
            .filter { pane in
                guard let dismissal = dismissed[pane.id] else { return true }
                return !dismissal.silences(pane)
            }
            .filter { pane in
                !(mutedPaneIDs.contains(pane.id) && pane.agentStatus != .blocked)
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

    /// Drops a dismissal as soon as its pane leaves the episode it was
    /// dismissed at, so a dismissal silences one *episode* rather than the
    /// status value forever. Without this, clicking a finished session's chip
    /// once retired every later `.done` for that pane and completed agents
    /// quietly stopped appearing on the HUD. Entries for panes that vanished
    /// are dropped too.
    ///
    /// The episode check is what makes a dismissal safe to persist across
    /// relaunch: a restored `.done` dismissal cannot silence a *new* `.done`
    /// that arrived overnight, because the new answer carries a new stamp.
    static func prunedDismissals(
        _ dismissed: [String: HudChipDismissal],
        machineID: String,
        panes: [HerdrPane]
    ) -> [String: HudChipDismissal] {
        var livePanes: [String: HerdrPane] = [:]
        for pane in panes {
            livePanes[pane.id] = pane
        }
        return dismissed.filter { paneID, dismissal in
            guard MachineScopedID.split(paneID)?.machineID == machineID else { return true }
            guard let pane = livePanes[paneID] else { return false }
            return dismissal.silences(pane)
        }
    }

    /// Newest-first cap for the persisted store, so a long-lived install cannot
    /// grow the dismissal map without bound.
    static func capped(_ dismissed: [String: HudChipDismissal], limit: Int) -> [String: HudChipDismissal] {
        guard dismissed.count > limit else { return dismissed }
        let newest = dismissed
            .sorted { left, right in
                if left.value.dismissedAt != right.value.dismissedAt {
                    return left.value.dismissedAt > right.value.dismissedAt
                }
                return left.key < right.key
            }
            .prefix(max(0, limit))
        return Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
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
