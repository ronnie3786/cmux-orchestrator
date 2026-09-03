import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Herdr HUD session chips")
struct HerdrHudSessionChipsTests {
    @Test("Working chip glow is static, so collapsed HUD chips do not animate")
    func chipMotionPolicy() {
        #expect(HerdrHudChipMotion.showsStaticGlow(for: .working))
        #expect(!HerdrHudChipMotion.showsStaticGlow(for: .blocked))
        #expect(!HerdrHudChipMotion.showsStaticGlow(for: .done))
        #expect(HerdrHudChipMotion.workingGlowOpacity > 0)
        #expect(HerdrHudChipMotion.workingGlowOpacity < 1)
    }

    @Test("Only blocked, done, and working Pi sessions qualify")
    func filtersStatusesAndNonPiPanes() throws {
        let result = HerdrHudSessionChips.chips(
            panes: [
                try pane(id: "blocked", status: .blocked),
                try pane(id: "done", status: .done),
                try pane(id: "working", status: .working),
                try pane(id: "idle", status: .idle),
                try pane(id: "unknown", status: .unknown),
                try pane(id: "shell", status: .working, piCapable: false),
            ],
            mutedPaneIDs: [],
            dismissedStatuses: [:],
            revealTitles: true,
            limit: 10
        )

        #expect(Set(result.chips.map(\.id)) == ["m1|blocked", "m1|done", "m1|working"])
    }

    @Test("Chips sort by attention rank, activity, revision, then id")
    func sortsDeterministically() throws {
        let newer = Date(timeIntervalSince1970: 200)
        let older = Date(timeIntervalSince1970: 100)
        let result = HerdrHudSessionChips.chips(
            panes: [
                try pane(id: "working", status: .working, revision: 1, workingSince: newer),
                try pane(id: "done-older", status: .done, revision: 99, lastActivityAt: older),
                try pane(id: "blocked-low", status: .blocked, revision: 1, lastActivityAt: newer),
                try pane(id: "blocked-high", status: .blocked, revision: 3, lastActivityAt: newer),
                try pane(id: "blocked-id-a", status: .blocked, revision: 3, lastActivityAt: newer),
                try pane(id: "done-newer", status: .done, revision: 1, lastActivityAt: newer),
            ],
            mutedPaneIDs: [],
            dismissedStatuses: [:],
            revealTitles: true,
            limit: 10
        )

        #expect(result.chips.map(\.id) == [
            "m1|blocked-high",
            "m1|blocked-id-a",
            "m1|blocked-low",
            "m1|done-newer",
            "m1|done-older",
            "m1|working",
        ])
    }

    @Test("Dismissal suppresses only the matching current status")
    func dismissalIsStatusScoped() throws {
        let done = try pane(id: "transition", status: .done)
        let working = try pane(id: "transition", status: .working)
        let dismissed = [done.id: AgentStatus.done]

        #expect(
            HerdrHudSessionChips.chips(
                panes: [done], mutedPaneIDs: [], dismissedStatuses: dismissed, revealTitles: true
            ).chips.isEmpty
        )
        #expect(
            HerdrHudSessionChips.chips(
                panes: [working], mutedPaneIDs: [], dismissedStatuses: dismissed, revealTitles: true
            ).chips.map(\.id) == [working.id]
        )
    }

    @Test("Mute hides progress states but keeps blocked sessions visible")
    func muteIsStatusScopedAndBlockedRemainsReversible() throws {
        let working = try pane(id: "working", status: .working)
        let done = try pane(id: "done", status: .done)
        let blocked = try pane(id: "blocked", status: .blocked)
        let result = HerdrHudSessionChips.chips(
            panes: [working, done, blocked],
            mutedPaneIDs: [working.id, done.id, blocked.id],
            dismissedStatuses: [:],
            revealTitles: true
        )

        #expect(result.chips.map(\.id) == [blocked.id])
        #expect(result.chips.first?.isMuted == true)
    }

    @Test("Redaction hides titles without redacting the routable pane id")
    func redactsOnlyDisplayTitle() throws {
        let pane = try pane(id: "secret-work", status: .working, title: "Confidential launch plan")
        let result = HerdrHudSessionChips.chips(
            panes: [pane], mutedPaneIDs: [], dismissedStatuses: [:], revealTitles: false
        )
        let chip = try #require(result.chips.first)

        #expect(chip.title == "session 1")
        #expect(!chip.title.localizedCaseInsensitiveContains("confidential"))
        #expect(chip.id == "m1|secret-work")
    }

    @Test("Limit caps chips and returns the exact remainder as overflow")
    func reportsOverflow() throws {
        let panes = try (1...5).map { index in
            try pane(id: "pane-\(index)", status: .working, revision: index)
        }
        let result = HerdrHudSessionChips.chips(
            panes: panes, mutedPaneIDs: [], dismissedStatuses: [:], revealTitles: true, limit: 2
        )

        #expect(result.chips.count == 2)
        #expect(result.overflow == 3)
    }

    /// What the `+N` control does: the same projection at the expanded limit
    /// returns every candidate and nothing left over.
    @Test("The expanded limit reveals every grouped session")
    func expandedLimitRevealsGroupedSessions() throws {
        let panes = try (1...5).map { index in
            try pane(id: "pane-\(index)", status: .working, revision: index)
        }
        let grouped = HerdrHudSessionChips.chips(
            panes: panes,
            mutedPaneIDs: [],
            dismissedStatuses: [:],
            revealTitles: true,
            limit: HerdrHudPlacement.maxChips
        )
        let revealed = HerdrHudSessionChips.chips(
            panes: panes,
            mutedPaneIDs: [],
            dismissedStatuses: [:],
            revealTitles: true,
            limit: HerdrHudPlacement.maxExpandedChips
        )

        #expect(grouped.chips.count == HerdrHudPlacement.maxChips)
        #expect(grouped.overflow == panes.count - HerdrHudPlacement.maxChips)
        #expect(revealed.chips.count == panes.count)
        #expect(revealed.overflow == 0)
        #expect(revealed.chips.prefix(grouped.chips.count).map(\.id) == grouped.chips.map(\.id))
    }

    @Test("A dismissed chip returns once its agent finishes again")
    func dismissalSilencesOneEpisodeNotTheStatus() throws {
        let working = try pane(id: "a", status: .working)
        let done = try pane(id: "a", status: .done)

        // The user clicked the chip while the agent was finished, which both
        // opens the pane and dismisses the chip.
        var dismissed: [String: AgentStatus] = ["m1|a": .done]
        #expect(HerdrHudSessionChips.chips(
            panes: [done],
            mutedPaneIDs: [],
            dismissedStatuses: dismissed,
            revealTitles: true
        ).chips.isEmpty)

        // The agent picks the work back up: the dismissal no longer applies.
        dismissed = HerdrHudSessionChips.prunedDismissals(dismissed, machineID: "m1", panes: [working])
        #expect(dismissed.isEmpty)

        // ...and when it finishes again the chip is back, which is the bug that
        // had completed agents disappearing from the HUD one session at a time.
        dismissed = HerdrHudSessionChips.prunedDismissals(dismissed, machineID: "m1", panes: [done])
        #expect(HerdrHudSessionChips.chips(
            panes: [done],
            mutedPaneIDs: [],
            dismissedStatuses: dismissed,
            revealTitles: true
        ).chips.map(\.id) == ["m1|a"])
    }

    @Test("A dismissal survives while its pane stays in the dismissed status")
    func dismissalSurvivesUnchangedStatus() throws {
        let done = try pane(id: "a", status: .done)
        let pruned = HerdrHudSessionChips.prunedDismissals(
            ["m1|a": .done],
            machineID: "m1",
            panes: [done]
        )
        #expect(pruned == ["m1|a": .done])
    }

    @Test("Pruning drops vanished panes but never another machine's dismissals")
    func pruningIsScopedToTheRefreshedMachine() throws {
        let pruned = HerdrHudSessionChips.prunedDismissals(
            ["m1|gone": .done, "m2|other": .done],
            machineID: "m1",
            panes: []
        )
        #expect(pruned == ["m2|other": .done])
    }

    @Test("An unviewed pane result survives idle, mute, and chip dismissal")
    func resultKeepsPaneChipVisible() throws {
        let idle = try pane(id: "finished", status: .idle)
        let resultArtifact = artifact(id: "artifact-1", originID: "finished")

        let result = HerdrHudSessionChips.chips(
            panes: [idle],
            mutedPaneIDs: [idle.id],
            dismissedStatuses: [idle.id: .idle],
            revealTitles: true,
            artifacts: [resultArtifact]
        )

        #expect(result.chips.map(\.id) == [idle.id])
        #expect(result.chips.first?.artifacts.map(\.id) == [resultArtifact.id])
        #expect(result.detachedArtifacts.isEmpty)
    }

    @Test("Headless and vanished-pane results dock to the HUD orb")
    func detachedResultsDockToOrb() throws {
        let livePane = try pane(id: "live", status: .done)
        let headless = artifact(
            id: "run-result",
            originType: .agentRun,
            originID: "run-1"
        )
        let vanished = artifact(id: "pane-result", originID: "gone")

        let result = HerdrHudSessionChips.chips(
            panes: [livePane],
            mutedPaneIDs: [],
            dismissedStatuses: [:],
            revealTitles: true,
            artifacts: [headless, vanished]
        )

        #expect(Set(result.detachedArtifacts.map(\.id)) == [headless.id, vanished.id])
    }

    @Test("A result from an overflowed session remains visible at the orb")
    func overflowedResultRemainsVisible() throws {
        let panes = try (1...4).map { index in
            try pane(id: "blocked-\(index)", status: .blocked, revision: index)
        }
        let overflowed = artifact(id: "overflowed", originID: "blocked-1")

        let grouped = HerdrHudSessionChips.chips(
            panes: panes,
            mutedPaneIDs: [],
            dismissedStatuses: [:],
            revealTitles: true,
            artifacts: [overflowed],
            limit: 3
        )
        let revealed = HerdrHudSessionChips.chips(
            panes: panes,
            mutedPaneIDs: [],
            dismissedStatuses: [:],
            revealTitles: true,
            artifacts: [overflowed],
            limit: 4
        )

        #expect(grouped.detachedArtifacts.map(\.id) == [overflowed.id])
        #expect(revealed.detachedArtifacts.isEmpty)
        #expect(revealed.chips.last?.artifacts.map(\.id) == [overflowed.id])
    }

    private func pane(
        id: String,
        status: AgentStatus,
        revision: Int = 1,
        title: String? = nil,
        piCapable: Bool = true,
        lastActivityAt: Date? = nil,
        workingSince: Date? = nil
    ) throws -> HerdrPane {
        var payload: [String: Any] = [
            "pane_id": id,
            "workspace_id": "w1",
            "tab_id": "t1",
            "agent_status": status.rawValue,
            "revision": revision,
        ]
        if let title { payload["title"] = title }
        if piCapable {
            payload["pi_semantic"] = ["available": true, "protocol_version": 1]
        }
        if let lastActivityAt {
            payload["last_activity_at"] = HerdrTimestamp.string(from: lastActivityAt)
        }
        if let workingSince {
            payload["working_since"] = HerdrTimestamp.string(from: workingSince)
        }
        return try JSONDecoder().decode(
            HerdrPane.self,
            from: try JSONSerialization.data(withJSONObject: payload)
        )
        .stamped(machineID: "m1")
    }

    private func artifact(
        id: String,
        originType: AgentResultArtifact.OriginType = .pane,
        originID: String
    ) -> AgentResultArtifact {
        AgentResultArtifact(
            id: id,
            originType: originType,
            originID: originID,
            kind: .file,
            title: "Result \(id)",
            filename: "result.pdf",
            contentType: "application/pdf",
            byteSize: 42,
            createdAt: HerdrTimestamp.string(from: .now),
            downloadPath: "/api/v1/result-artifacts/\(id)/content"
        )
        .stamped(machineID: "m1")
    }
}
