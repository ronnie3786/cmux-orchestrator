import Foundation

/// Joins durable voice assignments to live HUD chips by machine and pane.
/// An agent gets a notification during dispatch, before the pane stream has
/// discovered it, and keeps the same row once that stream catches up.
@MainActor
enum QuickVoiceHudProjection {
    typealias Projection = (chips: [HerdrHudSessionChips.Chip], overflow: Int, detachedArtifacts: [AgentResultArtifact])

    static func chips(
        panes: [HerdrPane],
        notes: [QuickVoiceSession.Note],
        mutedPaneIDs: Set<String>,
        dismissed: [String: HudChipDismissal],
        revealTitles: Bool,
        artifacts: [AgentResultArtifact],
        showAll: Bool
    ) -> Projection {
        let base = HerdrHudSessionChips.chips(
            panes: panes, mutedPaneIDs: mutedPaneIDs, dismissed: dismissed,
            revealTitles: revealTitles, artifacts: artifacts, limit: Int.max
        )
        var remaining = Dictionary(uniqueKeysWithValues: base.chips.map { ($0.id, $0) })
        let livePanes = Dictionary(panes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var voiceChips: [HerdrHudSessionChips.Chip] = []
        var seen: Set<String> = []
        for note in notes.sorted(by: { $0.job.createdAt > $1.job.createdAt }) {
            for (index, task) in note.job.tasks.enumerated() {
                let id = task.paneID.map { MachineScopedID.compose(machineID: note.machineID, rawID: $0) }
                    ?? "voice:\(note.id):\(index)"
                guard seen.insert(id).inserted else { continue }
                let existing = remaining[id]
                // Finished history can annotate a live notification, but may
                // not resurrect one the user already opened or dismissed.
                guard !note.job.isFinished || existing != nil else { continue }
                let status = note.job.isFinished ? existing?.status ?? task.hudStatus : task.hudStatus
                guard !mutedPaneIDs.contains(id) || status == .blocked else { continue }
                if let pane = livePanes[id], dismissed[id]?.silences(pane) == true { continue }
                remaining.removeValue(forKey: id)
                voiceChips.append(.init(
                    id: id,
                    title: revealTitles ? task.title : "Voice agent \(index + 1)",
                    status: status,
                    isMuted: mutedPaneIDs.contains(id),
                    since: existing?.since ?? Date(timeIntervalSince1970: note.job.createdAt),
                    artifacts: existing?.artifacts ?? [],
                    voiceNoteID: note.id,
                    detail: note.job.isFinished && status != task.hudStatus ? status.title : task.statusLabel,
                    symbol: note.job.isFinished && status != task.hudStatus ? nil : task.statusSymbol
                ))
            }
        }
        let all = voiceChips + base.chips.filter { remaining[$0.id] != nil }
        // A single request may start four agents. Show all four without an
        // extra click, while keeping the ordinary HUD's three-row default.
        let limit = showAll ? HerdrHudPlacement.maxExpandedChips : max(HerdrHudPlacement.maxChips, min(4, voiceChips.count))
        let visible = Array(all.prefix(limit))
        let attachedIDs = Set(visible.flatMap(\.artifacts).map(\.id))
        return (visible, max(0, all.count - limit), artifacts.filter { !attachedIDs.contains($0.id) })
    }
}
