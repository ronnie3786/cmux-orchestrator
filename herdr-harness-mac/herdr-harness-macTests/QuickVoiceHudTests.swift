import Foundation
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("Voice requests in the HUD", .serialized)
@MainActor
struct QuickVoiceHudTests {
    @Test("All four assignments appear before the live pane stream catches up")
    func dispatchNotifications() {
        let note = makeNote(statuses: ["pending", "starting", "sending", "running"])
        let result = project(notes: [note])
        #expect(result.chips.count == 4)
        #expect(result.overflow == 0)
        #expect(result.chips.map(\.detail) == ["Starting", "Starting", "Sending request", "Running"])
        #expect(result.chips.allSatisfy { $0.voiceNoteID == note.id })
    }

    @Test("Live panes merge into voice notifications without duplicates or title loss")
    func joinsLivePane() throws {
        let pane = try makePane(status: "working")
        let note = makeNote(statuses: ["running"])
        let result = project(notes: [note], panes: [pane])
        #expect(result.chips.count == 1)
        #expect(result.chips.first?.id == pane.id)
        #expect(result.chips.first?.title == "Check Slack notifications")
        #expect(result.chips.first?.detail == "Running")
    }

    @Test("Voice history respects dismissal and does not bring back idle or vanished panes")
    func respectsHistoryAndDismissal() throws {
        let done = try makePane(status: "done")
        let note = makeNote(statuses: ["done"], jobStatus: "done")
        let dismissed = [done.id: HudChipDismissal(pane: done, dismissedAt: .now)]
        #expect(project(notes: [note], panes: [done], dismissed: dismissed).chips.isEmpty)
        #expect(project(notes: [note]).chips.isEmpty)
        #expect(project(notes: [note], panes: [try makePane(status: "idle")]).chips.isEmpty)
        #expect(project(notes: [note], panes: [done]).chips.first?.detail == "Finished")
    }

    @Test("A reused pane's live status wins over an older completed voice request")
    func resumedAgent() throws {
        let result = project(notes: [makeNote(statuses: ["done"], jobStatus: "done")], panes: [try makePane(status: "working")])
        #expect(result.chips.first?.status == .working)
        #expect(result.chips.first?.detail != "Finished")
    }

    @Test("Titles honor privacy and muted running agents stay hidden")
    func privacyAndMute() {
        let note = makeNote(statuses: ["running", "needs_attention"])
        let result = project(notes: [note], muted: ["demo1|w1:p1", "demo1|w1:p2"], revealTitles: false)
        #expect(result.chips.count == 1)
        #expect(result.chips.first?.title == "Voice agent 2")
        #expect(result.chips.first?.status == .blocked)
        #expect(result.chips.first?.isMuted == true)
    }

    @Test("Choosing a previous request cannot replace an in-flight recording")
    func receiptSelection() throws {
        let defaults = try makeDefaults()
        let session = QuickVoiceSession(defaults: defaults)
        let note = makeNote(statuses: ["running"])
        session.seedForTesting(notes: [note], phase: .transcribing)
        session.selectNote(note.id)
        #expect(session.selectedNote == nil)
        session.seedForTesting(notes: [note])
        session.selectNote(note.id)
        #expect(session.selectedNote?.job.text == note.job.text)
    }

    @Test("Voice receipt grows downward while keeping the orb's anchor fixed")
    func placement() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let collapsed = HerdrHudPlacement.frame(isExpanded: false, visibleFrame: screen, topRightOffset: .zero, chipCount: 3, hasVoiceChips: true)
        let receipt = HerdrHudPlacement.frame(isExpanded: false, visibleFrame: screen, topRightOffset: .zero, chipCount: 3, quickVoiceSize: HerdrHudPlacement.quickVoiceCardSize, hasVoiceChips: true)
        #expect(receipt.maxX == collapsed.maxX)
        #expect(receipt.maxY == collapsed.maxY)
        #expect(receipt.height == collapsed.height + HerdrHudPlacement.quickVoiceCardSize.height + HerdrHudPlacement.chipSpacing)
        #expect(receipt.width >= HerdrHudPlacement.quickVoiceCardSize.width + HerdrHudPlacement.shadowMargin * 2)
    }

    @Test("Request receipt and named agent notifications render together")
    func rendersRequestFlow() async throws {
        let defaults = try makeDefaults()
        let model = HerdrRenderFixtures.demoModel()
        let voice = QuickVoicePanelController(defaults: defaults)
        let controller = HerdrHudController(userDefaults: defaults)
        let hud = HerdrHudSession(userDefaults: defaults, persistenceURL: temporaryURL())
        let notes = HerdrHudNotesState(userDefaults: defaults, agentSettings: AgentModelSettingsStore(defaults: defaults), promptSettings: HerdrPromptSettingsStore(defaults: defaults), persistenceURL: temporaryURL())
        let fontScale = HerdrFontScaleStore()
        controller.configure(model: model, session: hud, notes: notes, fontScale: fontScale, quickVoice: voice)
        defer { controller.setEnabled(false) }
        let note = makeNote(statuses: ["done", "running", "needs_attention"])
        voice.session.seedForTesting(notes: [note], selectedNoteID: note.id)
        voice.showDetails()
        #expect(!controller.isExpanded)
        #expect(voice.isExpanded)
        let chips = project(notes: [note]).chips
        let result = try await HerdrRenderHarness.render("38-quick-voice-heard.png", size: CGSize(width: 400, height: 590)) {
            VStack(alignment: .trailing, spacing: HerdrHudPlacement.chipSpacing) {
                HerdrHudOrbResultRow(model: model, controller: controller, session: hud, artifacts: [])
                QuickVoiceDetailsView(controller: voice, session: voice.session, model: model)
                HerdrHudSessionChipsView(model: model, session: hud, chips: chips, overflow: 0)
            }
            .padding(24)
        }
        result.expectSubstantial()
        voice.session.seedForTesting(notes: [], phase: .recording)
        let recording = try await HerdrRenderHarness.render("39-quick-voice-recording.png", size: CGSize(width: 400, height: 450)) {
            VStack(alignment: .trailing, spacing: HerdrHudPlacement.chipSpacing) {
                HerdrHudOrbResultRow(model: model, controller: controller, session: hud, artifacts: [])
                QuickVoiceDetailsView(controller: voice, session: voice.session, model: model)
            }.padding(24)
        }
        recording.expectSubstantial()
        controller.handleCancel()
        #expect(!voice.isExpanded)
        #expect(voice.session.phase == .idle)
    }

    private func project(notes: [QuickVoiceSession.Note], panes: [HerdrPane] = [], dismissed: [String: HudChipDismissal] = [:], muted: Set<String> = [], revealTitles: Bool = true) -> QuickVoiceHudProjection.Projection {
        QuickVoiceHudProjection.chips(panes: panes, notes: notes, mutedPaneIDs: muted, dismissed: dismissed, revealTitles: revealTitles, artifacts: [], showAll: false)
    }

    private func makeNote(statuses: [String], jobStatus: String = "running") -> QuickVoiceSession.Note {
        let titles = ["Check Slack notifications", "Count draft PRs", "Count unread emails", "Review today's calendar"]
        let job = QuickVoiceJob(
            id: "voice-demo", text: "Check my unread Slack notifications, count my draft PRs, and tell me how many unread emails I have.", cwd: nil,
            title: "Slack, PRs and email", status: jobStatus, createdAt: Date().timeIntervalSince1970,
            tasks: statuses.enumerated().map { index, status in
                .init(title: titles[index], status: status, paneID: status == "pending" ? nil : "w1:p\(index + 1)", result: nil)
            }, messages: [], error: nil
        )
        return .init(machineID: "demo1", job: job)
    }

    private func makePane(status: String) throws -> HerdrPane {
        let payload: [String: Any] = ["pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "t1", "agent_status": status, "pi_semantic": ["available": true, "protocol_version": 1]]
        return try JSONDecoder().decode(HerdrPane.self, from: JSONSerialization.data(withJSONObject: payload)).stamped(machineID: "demo1")
    }

    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "QuickVoiceHudTests.\(UUID().uuidString)"))
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "voice-hud-\(UUID().uuidString).json")
    }
}
