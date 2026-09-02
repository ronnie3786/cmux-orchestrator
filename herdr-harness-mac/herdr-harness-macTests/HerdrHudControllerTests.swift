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

    @Test("Hover-driven notes layouts resize without animating the HUD panel")
    func hoverLayoutsDoNotAnimatePanelFrame() {
        #expect(!HerdrHudController.shouldAnimateNotesFrameTransition(from: .hidden, to: .rows(count: 0)))
        #expect(!HerdrHudController.shouldAnimateNotesFrameTransition(from: .compact(count: 3), to: .rows(count: 3)))
        #expect(!HerdrHudController.shouldAnimateNotesFrameTransition(from: .rows(count: 3), to: .compact(count: 3)))
    }

    @Test("The +N control reveals grouped sessions and holds while hovered")
    func chipOverflowRevealsAndHolds() async throws {
        let harness = makeHarness(chipRegroupDelay: .milliseconds(120))
        #expect(!harness.controller.isShowingAllChips)

        harness.controller.showAllChips()
        #expect(harness.controller.isShowingAllChips)

        harness.controller.setHoveringChips(true)
        try await Task.sleep(for: .milliseconds(260))
        #expect(harness.controller.isShowingAllChips)
    }

    @Test("Revealed sessions regroup once the pointer has left for the delay")
    func chipOverflowRegroupsAfterHover() async throws {
        let harness = makeHarness(chipRegroupDelay: .milliseconds(120))
        harness.controller.showAllChips()
        harness.controller.setHoveringChips(true)
        harness.controller.setHoveringChips(false)

        #expect(harness.controller.isShowingAllChips)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!harness.controller.isShowingAllChips)
    }

    @Test("Returning to the chips cancels a pending regroup")
    func chipOverflowHoverCancelsRegroup() async throws {
        let harness = makeHarness(chipRegroupDelay: .milliseconds(200))
        harness.controller.showAllChips()
        harness.controller.setHoveringChips(false)
        try await Task.sleep(for: .milliseconds(60))
        harness.controller.setHoveringChips(true)

        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.controller.isShowingAllChips)
    }

    @Test("Summoning the HUD regroups the revealed sessions")
    func summonRegroupsChips() async throws {
        let harness = makeHarness()
        harness.controller.showAllChips()
        harness.controller.summon()
        #expect(!harness.controller.isShowingAllChips)
    }

    /// The panel used to clamp its chip count at `maxChips`, which would have
    /// left revealed sessions drawn outside the window.
    @Test("The panel accepts more chips than the grouped limit, up to the expanded one")
    func revealedChipsGrowThePanel() async throws {
        let harness = makeHarness()
        harness.controller.setCollapsedChipCount(HerdrHudPlacement.maxChips + 2)
        #expect(harness.controller.collapsedChipCount == HerdrHudPlacement.maxChips + 2)

        harness.controller.setCollapsedChipCount(HerdrHudPlacement.maxExpandedChips + 5)
        #expect(harness.controller.collapsedChipCount == HerdrHudPlacement.maxExpandedChips)
    }

    @Test("Opening and closing a note card retain their panel animation")
    func cardLayoutsAnimatePanelFrame() {
        #expect(HerdrHudController.shouldAnimateNotesFrameTransition(from: .rows(count: 2), to: .card))
        #expect(HerdrHudController.shouldAnimateNotesFrameTransition(from: .card, to: .compact(count: 2)))
    }

    private struct Harness {
        let model: HerdrAppModel
        let session: HerdrHudSession
        let notes: HerdrHudNotesState
        let controller: HerdrHudController
    }

    private func makeHarness(chipRegroupDelay: Duration = .seconds(5)) -> Harness {
        let defaults = makeDefaults()
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"], userDefaults: defaults)
        let agentSettings = AgentModelSettingsStore(defaults: defaults)
        let promptSettings = HerdrPromptSettingsStore(defaults: defaults)
        let session = HerdrHudSession(userDefaults: defaults, agentSettings: agentSettings, persistenceURL: temporaryURL(named: "hud-thread.json"), promptSettings: promptSettings)
        let notes = HerdrHudNotesState(userDefaults: defaults, agentSettings: agentSettings, promptSettings: promptSettings, persistenceURL: temporaryURL(named: "hud-notes.json"), hoverGrace: .zero, hoverDelay: .zero, saveDelay: .zero)
        let controller = HerdrHudController(userDefaults: defaults, chipRegroupDelay: chipRegroupDelay)
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
