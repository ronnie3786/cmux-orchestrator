import Foundation
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("Herdr HUD renders", .serialized)
@MainActor
struct HudRenderTests {
    @Test("HUD card renders completed transcript rows")
    func rendersHudCard() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let session = HerdrHudSession(
            userDefaults: makeDefaults(),
            persistenceURL: temporaryPersistenceURL()
        )
        session.seedExchangesForTesting([
            HerdrHudExchange(
                id: "hud-fleet-status",
                machineID: "demo1",
                prompt: "What is the current status of the demo fleet?",
                sentPrompt: "What is the current status of the demo fleet?",
                response: "The fleet is healthy. Two alerts need attention, and one pane is waiting for review.",
                error: nil,
                status: .completed,
                costUSD: nil,
                createdAt: .now,
                promotedPaneID: nil,
                attachmentFilenames: []
            ),
            HerdrHudExchange(
                id: "hud-resolve-alert",
                machineID: "demo1",
                prompt: "Resolve the stale attention alert and summarize the change.",
                sentPrompt: "Resolve the stale attention alert and summarize the change.",
                response: "Resolved the stale alert, refreshed its status, and left the active pane open for review.",
                error: nil,
                status: .completed,
                costUSD: 0.0042,
                createdAt: .now,
                promotedPaneID: nil,
                attachmentFilenames: ["alert-screenshot.png"]
            ),
        ])

        let result = try await HerdrRenderHarness.render(
            "15-hud-card.png",
            size: CGSize(width: 420, height: 580)
        ) {
            HerdrHudCardView(
                model: model,
                controller: HerdrHudController(),
                session: session
            )
        }

        result.expectSubstantial()
    }

    @Test("HUD orb renders its unread-alert attention badge")
    func rendersHudOrb() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let session = HerdrHudSession(
            userDefaults: makeDefaults(),
            persistenceURL: temporaryPersistenceURL()
        )
        #expect(model.unreadAlertCount > 0)

        let result = try await HerdrRenderHarness.render(
            "16-hud-orb.png",
            size: CGSize(width: 100, height: 100)
        ) {
            HerdrHudOrbView(
                model: model,
                controller: HerdrHudController(),
                session: session
            )
            .frame(width: 100, height: 100)
        }

        result.expectSubstantial()
    }

    @Test("HUD session chips render in the collapsed strip")
    func rendersHudSessionChips() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let chips = [
            HerdrHudSessionChips.Chip(
                id: "demo1|w1:p1",
                title: "Working session",
                status: .working,
                isMuted: false,
                since: .now
            ),
            HerdrHudSessionChips.Chip(
                id: "demo2|w2:p1",
                title: "Ready session",
                status: .done,
                isMuted: false,
                since: .now
            ),
        ]

        let result = try await HerdrRenderHarness.render(
            "17-hud-session-chips.png",
            size: HerdrHudPlacement.collapsedContentSize(chipCount: 2)
        ) {
            HerdrHudSessionChipsView(
                model: model,
                chips: chips,
                overflow: 0
            )
        }

        result.expectSubstantial()
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "HudRenderTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create isolated render defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func temporaryPersistenceURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("HudRenderTests-\(UUID().uuidString)-hud-thread.json")
    }
}
