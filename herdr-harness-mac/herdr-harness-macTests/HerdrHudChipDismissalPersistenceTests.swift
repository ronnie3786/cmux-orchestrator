import Foundation
import Testing
@testable import herdr_harness_mac

/// Chip dismissals used to live only in memory, so every relaunch resurrected
/// every chip the user had already cleared — one of the reasons HUD
/// notifications appeared never to go away.
///
/// Note: demo panes are deliberately NOT pi-capable, so they never reach the
/// chip projection. The model is used here only for the persistence round trip;
/// the projection assertions use explicit pi-capable fixtures, or they would
/// pass vacuously.
@Suite("Herdr HUD chip dismissal persistence")
struct HerdrHudChipDismissalPersistenceTests {
    @MainActor
    @Test("A dismissal is written to defaults and restored by the next launch")
    func chipDismissalSurvivesRelaunch() throws {
        let suiteName = "HerdrHudChipDismissalPersistenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = HerdrAppModel(arguments: ["-HerdrDemoMode"], userDefaults: defaults)
        let paneID = "demo1|w1:p1"
        model.dismissHudChip(paneID)
        let recorded = try #require(model.dismissedHudChips[paneID])

        // A second model over the same defaults is what a relaunch looks like.
        let relaunched = HerdrAppModel(arguments: ["-HerdrDemoMode"], userDefaults: defaults)
        #expect(relaunched.dismissedHudChips[paneID] == recorded)
    }

    @MainActor
    @Test("Removing a machine erases its dismissals from disk too")
    func removingAMachineErasesItsDismissals() throws {
        let suiteName = "HerdrHudChipDismissalPersistenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = HerdrAppModel(arguments: ["-HerdrDemoMode"], userDefaults: defaults)
        model.dismissHudChip("demo1|w1:p1")
        model.dismissHudChip("demo2|w2:p1")
        model.removeMachine(id: "demo1")

        let relaunched = HerdrAppModel(arguments: ["-HerdrDemoMode"], userDefaults: defaults)
        #expect(relaunched.dismissedHudChips["demo1|w1:p1"] == nil)
        #expect(relaunched.dismissedHudChips["demo2|w2:p1"] != nil)
    }

    /// The whole reason the dismissal carries an episode: a restored map must
    /// silence the answer it was dismissed for and nothing after it.
    @Test("A restored dismissal silences its own episode but not the next answer")
    func restoredDismissalSilencesOnlyItsOwnEpisode() throws {
        let dismissedAnswer = try pane(status: .done, lastActivityAt: Date(timeIntervalSince1970: 100))
        let nextAnswer = try pane(status: .done, lastActivityAt: Date(timeIntervalSince1970: 500))

        let stored = [dismissedAnswer.id: HudChipDismissal(pane: dismissedAnswer, dismissedAt: .now)]
        // Round-trip through the same encoding the defaults store uses, so this
        // covers the persisted representation and not just the in-memory value.
        let data = try JSONEncoder().encode(stored)
        let restored = try JSONDecoder().decode([String: HudChipDismissal].self, from: data)
        #expect(restored == stored)

        #expect(HerdrHudSessionChips.chips(
            panes: [dismissedAnswer], mutedPaneIDs: [], dismissed: restored, revealTitles: true
        ).chips.isEmpty)

        #expect(HerdrHudSessionChips.chips(
            panes: [nextAnswer], mutedPaneIDs: [], dismissed: restored, revealTitles: true
        ).chips.map(\.id) == [nextAnswer.id])
    }

    @MainActor
    @Test("A garbage stored payload loads as an empty map")
    func corruptStoreLoadsEmpty() throws {
        let suiteName = "HerdrHudChipDismissalPersistenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Data("not json".utf8), forKey: "herdr.hud.dismissedChips.v1")
        let model = HerdrAppModel(arguments: ["-HerdrDemoMode"], userDefaults: defaults)
        #expect(model.dismissedHudChips.isEmpty)
    }

    private func pane(status: AgentStatus, lastActivityAt: Date) throws -> HerdrPane {
        let payload: [String: Any] = [
            "pane_id": "w1:p1",
            "workspace_id": "w1",
            "tab_id": "t1",
            "agent_status": status.rawValue,
            "revision": 1,
            "pi_semantic": ["available": true, "protocol_version": 1],
            "last_activity_at": HerdrTimestamp.string(from: lastActivityAt),
        ]
        return try JSONDecoder().decode(
            HerdrPane.self,
            from: try JSONSerialization.data(withJSONObject: payload)
        )
        .stamped(machineID: "m1")
    }
}
