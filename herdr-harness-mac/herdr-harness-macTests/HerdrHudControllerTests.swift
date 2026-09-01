import CoreGraphics
import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Herdr HUD controller", .serialized)
@MainActor
struct HerdrHudControllerTests {
    @Test("Summon, open, and summon again drive expansion and note state together")
    func summonOpenNoteRoundTrip() async throws {
        let harness = makeHarness()
        harness.controller.summon()
        #expect(harness.controller.isExpanded)
        #expect(harness.notes.isHudExpanded)

        let noteID = harness.notes.createNote()
        harness.controller.openNote(noteID)
        #expect(!harness.controller.isExpanded)
        #expect(harness.session.isCollapsed)
        #expect(harness.notes.openNoteID == noteID)
        #expect(!harness.notes.isHudExpanded)

        harness.controller.summon()
        #expect(harness.notes.openNoteID == nil)
        #expect(harness.notes.isHudExpanded)
    }

    @Test("handleCancel with a note open closes only the note")
    func handleCancelClosesNoteFirst() async throws {
        let harness = makeHarness()
        let noteID = harness.notes.createNote()
        harness.controller.openNote(noteID)
        harness.controller.handleCancel()
        #expect(harness.notes.openNoteID == nil)
    }

    @Test("Disabling the HUD closes an open note")
    func disablingClosesOpenNote() async throws {
        let harness = makeHarness()
        let noteID = harness.notes.createNote()
        harness.controller.openNote(noteID)
        harness.controller.setEnabled(false)
        #expect(harness.notes.openNoteID == nil)
    }

    @Test("Opening a note grows the panel frame by the note card size")
    func openNoteGrowsPanelFrame() async throws {
        let harness = makeHarness()
        let beforeHeight = try #require(harness.controller.panelFrameForTesting?.height)
        let noteID = harness.notes.createNote()
        harness.controller.openNote(noteID)
        try await Task.sleep(for: .milliseconds(300))
        let afterHeight = try #require(harness.controller.panelFrameForTesting?.height)
        #expect(afterHeight - beforeHeight == HerdrHudPlacement.notesGap + HerdrHudPlacement.noteCardSize.height)
    }

    private struct Harness {
        let model: HerdrAppModel
        let session: HerdrHudSession
        let notes: HerdrHudNotesState
        let controller: HerdrHudController
    }

    private func makeHarness() -> Harness {
        let defaults = makeDefaults()
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"], userDefaults: defaults)
        let agentSettings = AgentModelSettingsStore(defaults: defaults)
        let promptSettings = HerdrPromptSettingsStore(defaults: defaults)
        let session = HerdrHudSession(userDefaults: defaults, agentSettings: agentSettings, persistenceURL: temporaryURL(named: "hud-thread.json"), promptSettings: promptSettings)
        let notes = HerdrHudNotesState(userDefaults: defaults, agentSettings: agentSettings, promptSettings: promptSettings, persistenceURL: temporaryURL(named: "hud-notes.json"), hoverGrace: .zero, hoverDelay: .zero, saveDelay: .zero)
        let controller = HerdrHudController(userDefaults: defaults)
        controller.configure(model: model, session: session, notes: notes, fontScale: HerdrFontScaleStore())
        return Harness(model: model, session: session, notes: notes, controller: controller)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "HerdrHudControllerTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { preconditionFailure("Could not create isolated defaults") }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func temporaryURL(named name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
    }
}
