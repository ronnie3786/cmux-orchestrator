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
}
