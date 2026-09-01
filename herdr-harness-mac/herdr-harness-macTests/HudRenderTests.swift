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

    @Test("HUD note card renders actions and links")
    func rendersHudNoteCard() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let agentSettings = AgentModelSettingsStore(defaults: makeDefaults())
        let promptSettings = HerdrPromptSettingsStore(defaults: makeDefaults())
        let notes = HerdrHudNotesState(
            userDefaults: makeDefaults(),
            agentSettings: agentSettings,
            promptSettings: promptSettings,
            persistenceURL: temporaryPersistenceURL(),
            hoverGrace: .zero,
            hoverDelay: .zero,
            saveDelay: .zero
        )
        await notes.waitForPersistenceRestoreForTesting()
        let id = UUID()
        let startedLink = HerdrNoteLink(
            id: UUID(),
            paneID: "w1:p1",
            machineID: "demo1",
            title: "Implementation session",
            createdAt: .now
        )
        let standaloneLink = HerdrNoteLink(
            id: UUID(),
            paneID: "w2:p1",
            machineID: "demo2",
            title: "Review session",
            createdAt: .now
        )
        var started = HerdrNoteAction(
            id: UUID(),
            title: "Open implementation session",
            prompt: "Continue the implementation",
            status: .started
        )
        started.linkID = startedLink.id
        let ready = HerdrNoteAction(
            id: UUID(),
            title: "Draft release notes",
            prompt: "Draft concise release notes",
            status: .ready
        )
        notes.seedNotesForTesting([
            HerdrNote(
                id: id,
                title: "HUD notes polish",
                body: "• Build the card\n• Check link handling\n• Verify animations\n• Capture the render",
                color: .lavender,
                aiSummary: "The note is ready to turn into focused sessions.",
                actions: [ready, started],
                links: [startedLink, standaloneLink]
            ),
        ])

        let result = try await HerdrRenderHarness.render(
            "18-hud-note-card.png",
            size: HerdrHudPlacement.noteCardSize
        ) {
            HerdrNoteCardView(model: model, controller: HerdrHudController(), notes: notes, noteID: id)
        }

        result.expectSubstantial()
    }

    @Test("HUD note rows render note signals")
    func rendersHudNoteRows() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let agentSettings = AgentModelSettingsStore(defaults: makeDefaults())
        let promptSettings = HerdrPromptSettingsStore(defaults: makeDefaults())
        let notes = HerdrHudNotesState(
            userDefaults: makeDefaults(),
            agentSettings: agentSettings,
            promptSettings: promptSettings,
            persistenceURL: temporaryPersistenceURL(),
            hoverGrace: .zero,
            hoverDelay: .zero,
            saveDelay: .zero
        )
        await notes.waitForPersistenceRestoreForTesting()
        let linked = HerdrNoteLink(
            id: UUID(), paneID: "w1:p1", machineID: "demo1", title: "Linked pane", createdAt: .now
        )
        let ready = HerdrNoteAction(id: UUID(), title: "Start a session", prompt: "Start", status: .ready)
        notes.seedNotesForTesting([
            HerdrNote(title: "Ready to ship", color: .yellow, actions: [ready]),
            HerdrNote(title: "Linked investigation", color: .green, links: [linked]),
            HerdrNote(title: "Quiet scratchpad", color: .blue),
        ])

        let result = try await HerdrRenderHarness.render(
            "19-hud-note-rows.png",
            size: CGSize(
                width: HerdrHudPlacement.notesWidth,
                height: HerdrHudPlacement.notesContentSize(.rows(count: 3), isExpanded: false).height
            )
        ) {
            HerdrNoteRowsView(model: model, controller: HerdrHudController(), notes: notes)
        }

        result.expectSubstantial()
    }

    @Test("HUD compact notes render color bars")
    func rendersHudCompactNotes() async throws {
        let agentSettings = AgentModelSettingsStore(defaults: makeDefaults())
        let promptSettings = HerdrPromptSettingsStore(defaults: makeDefaults())
        let notes = HerdrHudNotesState(
            userDefaults: makeDefaults(),
            agentSettings: agentSettings,
            promptSettings: promptSettings,
            persistenceURL: temporaryPersistenceURL(),
            hoverGrace: .zero,
            hoverDelay: .zero,
            saveDelay: .zero
        )
        await notes.waitForPersistenceRestoreForTesting()
        notes.seedNotesForTesting([
            HerdrNote(title: "Yellow", color: .yellow),
            HerdrNote(title: "Peach", color: .peach),
            HerdrNote(title: "Pink", color: .pink),
            HerdrNote(title: "Green", color: .green),
        ])

        let result = try await HerdrRenderHarness.render(
            "20-hud-note-compact.png",
            size: HerdrHudPlacement.notesContentSize(.compact(count: 4), isExpanded: false)
        ) {
            HerdrNoteCompactStackView(notes: notes, count: 4)
        }

        result.expectSubstantial(minimumBytes: 1024)
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
