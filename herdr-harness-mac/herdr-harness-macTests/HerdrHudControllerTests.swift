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

    @Test("Panel frame changes are deferred while dragging")
    func applyFrameIsSuppressedWhileDragging() throws {
        let harness = makeHarness()
        let before = try #require(harness.controller.panelFrameForTesting)

        harness.controller.beginPanelDrag()
        harness.controller.setCollapsedChipCount(2)

        #expect(harness.controller.panelFrameForTesting == before)
        harness.controller.endPanelDrag()
    }

    @Test("Ending a drag adopts the panel's actual frame as its placement")
    func endingDragAdoptsActualPanelFrame() throws {
        let harness = makeHarness()
        let initialOffset = harness.controller.placementOffsetForTesting
        let initialFrame = try #require(harness.controller.panelFrameForTesting)
        let movedFrame = initialFrame.offsetBy(dx: -100, dy: -100)

        harness.controller.beginPanelDrag()
        harness.controller.setPanelFrameForTesting(movedFrame)
        harness.controller.endPanelDrag()

        let adoptedOffset = harness.controller.placementOffsetForTesting
        #expect(adoptedOffset.width == initialOffset.width + 100)
        #expect(adoptedOffset.height == initialOffset.height + 100)
        let savedOffset = try #require(harness.defaults.array(forKey: "herdr.hud.offset.v2") as? [NSNumber])
        #expect(savedOffset.map(\.doubleValue) == [Double(adoptedOffset.width), Double(adoptedOffset.height)])
    }

    @Test("Panel dragging tracks its active state")
    func panelDraggingTracksItsActiveState() {
        let harness = makeHarness()
        #expect(!harness.controller.isDraggingPanel)
        harness.controller.beginPanelDrag()
        #expect(harness.controller.isDraggingPanel)
        harness.controller.endPanelDrag()
        #expect(!harness.controller.isDraggingPanel)
    }

    @Test("Suspended notes hover does not change hover state")
    func suspendedNotesHoverIsIgnored() async throws {
        let harness = makeHarness()
        harness.notes.isHoverSuspended = true
        harness.notes.setHovering(true)
        try await Task.sleep(for: .milliseconds(20))
        #expect(!harness.notes.isHovering)
    }

    @Test("A run auto-collapses the card and reopens it when the answer lands")
    func runAutoCollapseRoundTrip() {
        let harness = makeHarness()
        harness.controller.summon()
        #expect(harness.controller.isExpanded)

        #expect(harness.controller.beginRunAutoCollapse())
        #expect(!harness.controller.isExpanded)
        #expect(harness.controller.isAwaitingRunAutoOpen)

        harness.controller.endRunAutoCollapse()
        #expect(harness.controller.isExpanded)
        #expect(!harness.controller.isAwaitingRunAutoOpen)
    }

    @Test("Submitting from an already-collapsed HUD does not arm an auto-open")
    func autoCollapseIgnoresAnAlreadyCollapsedHud() {
        let harness = makeHarness()
        #expect(!harness.controller.isExpanded)

        #expect(!harness.controller.beginRunAutoCollapse())
        #expect(!harness.controller.isAwaitingRunAutoOpen)

        harness.controller.endRunAutoCollapse()
        #expect(!harness.controller.isExpanded)
    }

    @Test("Reopening or dismissing the HUD mid-run cancels the pending auto-open")
    func userGesturesCancelTheAutoOpen() {
        for gesture in ["summon", "collapse", "note"] {
            let harness = makeHarness()
            harness.controller.summon()
            harness.controller.beginRunAutoCollapse()
            #expect(harness.controller.isAwaitingRunAutoOpen)

            switch gesture {
            case "summon": harness.controller.summon()
            case "collapse": harness.controller.collapse()
            default: harness.controller.openNote(harness.notes.createNote())
            }
            #expect(!harness.controller.isAwaitingRunAutoOpen)

            // The run finishing must not now yank the HUD around.
            let before = harness.controller.isExpanded
            harness.controller.endRunAutoCollapse()
            #expect(harness.controller.isExpanded == before)
        }
    }

    @Test("A note opened while the run was in flight keeps the card shut")
    func autoOpenYieldsToAnOpenNote() {
        let harness = makeHarness()
        harness.controller.summon()
        harness.controller.beginRunAutoCollapse()
        let id = harness.notes.createNote()
        harness.notes.openNote(id)

        harness.controller.endRunAutoCollapse()

        #expect(!harness.controller.isExpanded)
    }

    private struct Harness {
        let defaults: UserDefaults
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
        return Harness(defaults: defaults, model: model, session: session, notes: notes, controller: controller)
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
