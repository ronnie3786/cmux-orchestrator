import Foundation
import SwiftUI
import Testing
@testable import herdr_harness_mac

@MainActor
final class FakeNoteAIRunner: HerdrNoteAIRunner {
    struct Call { let prompt: String; let machineID: String; let mode: HeadlessAgentRunMode; let systemPrompt: String?; let model: String?; let thinkingLevel: String? }
    enum Mode { case succeed(String), throwing(any Error), hanging }
    var mode: Mode = .succeed("")
    private(set) var calls: [Call] = []

    func run(prompt: String, machineID: String, mode: HeadlessAgentRunMode, model: String?, thinkingLevel: String?, systemPrompt: String?, deadline: Duration, appModel: HerdrAppModel, onProgress: @escaping @MainActor (HerdrNoteRunProgress) -> Void) async throws -> String {
        calls.append(Call(prompt: prompt, machineID: machineID, mode: mode, systemPrompt: systemPrompt, model: model, thinkingLevel: thinkingLevel))
        onProgress(HerdrNoteRunProgress(stepCount: 1, lastStep: "Read · note.txt"))
        switch self.mode {
        case let .succeed(text): return text
        case let .throwing(error): throw error
        case .hanging: try await Task.sleep(for: .seconds(60)); throw CancellationError()
        }
    }
}

@MainActor
final class FakeNoteSessionSpawner: HerdrNoteSessionSpawner {
    enum SpawnMode { case succeed(HerdrPane), throwing(any Error) }
    enum SendMode { case succeed, throwing(any Error) }
    var spawnMode: SpawnMode
    var sendMode: SendMode = .succeed
    private(set) var sendCalls: [(paneID: String, text: String)] = []

    init(spawnMode: SpawnMode) { self.spawnMode = spawnMode }

    func spawn(machineID: String, label: String, workspaceLabel: String, tabLabel: String, appModel: HerdrAppModel) async throws -> HerdrPane {
        switch spawnMode { case let .succeed(pane): return pane; case let .throwing(error): throw error }
    }

    func sendPrompt(to pane: HerdrPane, text: String, appModel: HerdrAppModel) async throws {
        sendCalls.append((pane.id, text))
        if case let .throwing(error) = sendMode { throw error }
    }
}

struct FakeNoteError: LocalizedError { let message: String; var errorDescription: String? { message } }

@Suite("Herdr HUD notes")
@MainActor
struct HerdrHudNotesStateTests {
    @Test("Creating and closing notes derives the expected layouts")
    func createsAndClosesNotes() async throws {
        let harness = await makeHarness()
        #expect(harness.state.layout == .hidden)
        let id = harness.state.createNote()
        #expect(harness.state.openNoteID == id)
        #expect(harness.state.notes.first?.id == id)
        #expect(harness.state.layout == .card)
        harness.state.isHudExpanded = true
        harness.state.closeNote()
        #expect(harness.state.layout == .rows(count: 1))
    }

    @Test("Hover and expansion select rows while rest uses compact notes")
    func hoverAndExpansionLayouts() async throws {
        let harness = await makeHarness()
        let id = harness.state.createNote()
        harness.state.closeNote()
        #expect(harness.state.layout == .compact(count: 1))
        harness.state.setHovering(true)
        try await Task.sleep(for: .milliseconds(20))
        #expect(harness.state.layout == .rows(count: 1))
        harness.state.setHovering(false)
        try await Task.sleep(for: .milliseconds(20))
        #expect(harness.state.layout == .compact(count: 1))
        harness.state.isHudExpanded = true
        #expect(harness.state.layout == .rows(count: 1))
        harness.state.deleteNote(id)
        #expect(harness.state.layout == .rows(count: 0))
    }

    @Test("Edits, undo, and deletion preserve note invariants")
    func editsUndoAndDelete() async throws {
        let harness = await makeHarness()
        let id = harness.state.createNote()
        let createdAt = try #require(harness.state.note(id: id)?.updatedAt)
        harness.state.setColor(.blue, for: id)
        #expect(harness.state.note(id: id)?.updatedAt == createdAt)
        harness.state.updateTitle("New", for: id)
        harness.state.updateBody("Body", for: id)
        let edited = try #require(harness.state.note(id: id))
        harness.state.seedNotesForTesting([HerdrNote(id: id, title: "After", body: "After body", previousVersion: HerdrNoteVersion(title: edited.title, body: edited.body, replacedAt: .now))])
        harness.state.undoAI(id)
        #expect(harness.state.note(id: id)?.title == "New")
        #expect(harness.state.note(id: id)?.previousVersion == nil)
        #expect(harness.state.revealRevision[id] == 1)
        harness.state.deleteNote(id)
        #expect(harness.state.note(id: id) == nil)
        #expect(harness.state.openNoteID == nil)
        #expect(harness.state.revealRevision[id] == nil)
    }

    @Test("Cleanup and planning apply parsed AI responses")
    func cleanupAndPlanning() async throws {
        let harness = await makeHarness()
        let id = harness.state.createNote()
        harness.state.updateTitle("Old", for: id)
        harness.state.updateBody("Original", for: id)
        harness.ai.mode = .succeed("# New Title\n\n• one\n• two")
        await harness.state.cleanUp(id, model: harness.model)
        let cleaned = try #require(harness.state.note(id: id))
        #expect(cleaned.title == "New Title")
        #expect(cleaned.body == "• one\n• two")
        #expect(cleaned.previousVersion?.title == "Old")
        #expect(harness.state.celebratingNoteID == id)
        #expect(!harness.state.isBusy(id))
        #expect(harness.ai.calls[0].systemPrompt == HerdrNoteAIPrompts.noToolsCharter)
        #expect(harness.ai.calls[0].thinkingLevel == "medium")
        #expect(harness.ai.calls[0].prompt.contains("<<<NOTE\nTitle: Old\n\nOriginal\nNOTE>>>"))
        harness.ai.mode = .succeed(#"{"summary":"s","actions":[{"title":"A","prompt":"do a"},{"title":"B","prompt":"do b"}]}"#)
        await harness.state.planActions(id, model: harness.model)
        #expect(harness.state.note(id: id)?.actions.count == 2)
        #expect(harness.state.note(id: id)?.aiSummary == "s")
        #expect(harness.state.note(id: id)?.actions.allSatisfy { $0.status == .ready } == true)
        #expect(harness.ai.calls[1].systemPrompt == HerdrNoteAIPrompts.planningCharter)
        #expect(harness.state.noteProgress[id] == nil)
    }

    @Test("Action launch links the pane and sends rendered context")
    func launchesAction() async throws {
        let harness = await makeHarness()
        let id = harness.state.createNote()
        let action = HerdrNoteAction(id: UUID(), title: "Do it", prompt: "Perform action")
        harness.state.seedNotesForTesting([HerdrNote(id: id, body: "Recognizable note", actions: [action])])
        await harness.state.runAction(action.id, in: id, model: harness.model)
        let note = try #require(harness.state.note(id: id))
        #expect(note.actions[0].status == .started)
        #expect(note.actions[0].linkID != nil)
        #expect(note.links.count == 1)
        #expect(harness.spawner.sendCalls.count == 1)
        #expect(harness.spawner.sendCalls[0].text.contains("Perform action"))
        #expect(harness.spawner.sendCalls[0].text.contains("Recognizable note"))
    }

    @Test("Machine absence fails before the AI runner is called")
    func noMachineFailsWithoutAI() async throws {
        let harness = await makeHarness()
        let id = harness.state.createNote()
        harness.model.machines = []
        await harness.state.cleanUp(id, model: harness.model)
        #expect(harness.state.noteErrors[id] == "No machine is available")
        #expect(harness.ai.calls.isEmpty)
    }

    @Test("Notes model falls back to the HUD model when unset")
    func notesModelFallsBackToHudModel() async throws {
        let harness = await makeHarness()
        harness.agentSettings.hudModel = "claude-hud-model"
        let id = harness.state.createNote()
        harness.state.updateBody("Body", for: id)
        harness.ai.mode = .succeed("Body")
        await harness.state.cleanUp(id, model: harness.model)
        #expect(harness.ai.calls.last?.model == "claude-hud-model")
    }

    @Test("Repeated cleanups keep the human original until the user edits")
    func secondCleanupKeepsHumanOriginal() async throws {
        let harness = await makeHarness()
        let id = harness.state.createNote()
        harness.state.updateTitle("Old", for: id)
        harness.state.updateBody("Original", for: id)

        harness.ai.mode = .succeed("# First\n\n• a")
        await harness.state.cleanUp(id, model: harness.model)
        harness.ai.mode = .succeed("# Second\n\n• b")
        await harness.state.cleanUp(id, model: harness.model)
        var note = try #require(harness.state.note(id: id))
        #expect(note.previousVersion?.body == "Original")
        #expect(note.body == "• b")

        harness.state.updateBody("Edited by hand", for: id)
        harness.ai.mode = .succeed("# Third\n\n• c")
        await harness.state.cleanUp(id, model: harness.model)
        note = try #require(harness.state.note(id: id))
        #expect(note.previousVersion?.body == "Edited by hand")

        harness.state.undoAI(id)
        note = try #require(harness.state.note(id: id))
        #expect(note.body == "Edited by hand")
    }

    @Test("Tidy flattens formatting but undo gives it back")
    func undoRestoresFormattingATidyFlattened() async throws {
        let harness = await makeHarness()
        let id = harness.state.createNote()
        var rich = AttributedString("keep me bold")
        rich.font = .body.bold()
        harness.state.updateBody(rich, for: id)

        // Tidy rewrites the note from a plain-text model reply, so the styling
        // goes — deliberately. The rich snapshot is the way back.
        harness.ai.mode = .succeed("# Tidy\n\n• flattened")
        await harness.state.cleanUp(id, model: harness.model)
        var note = try #require(harness.state.note(id: id))
        #expect(note.body == "• flattened")
        #expect(note.richBody.runs.allSatisfy { $0.font == nil })
        #expect(note.previousVersion?.richBody == rich)

        harness.state.undoAI(id)
        note = try #require(harness.state.note(id: id))
        #expect(note.richBody == rich)
    }

    @Test("Deleting a note mid-cleanup cancels the run and leaves no residue")
    func deleteWhileCleaning() async throws {
        let harness = await makeHarness()
        let id = harness.state.createNote()
        harness.state.updateBody("x", for: id)
        harness.ai.mode = .hanging
        let run = Task { await harness.state.cleanUp(id, model: harness.model) }
        while !harness.state.isBusy(id) { await Task.yield() }
        harness.state.deleteNote(id)
        await run.value
        #expect(harness.state.note(id: id) == nil)
        #expect(!harness.state.isBusy(id))
        #expect(harness.state.noteErrors[id] == nil)
        #expect(harness.state.celebratingNoteID == nil)
        #expect(harness.state.layout == .hidden)
    }

    @Test("Only ready or failed actions run; failed actions are reset")
    func runnableActionStatuses() async throws {
        let harness = await makeHarness()
        let id = harness.state.createNote()
        let started = HerdrNoteAction(id: UUID(), title: "S", prompt: "p", status: .started)
        var failed = HerdrNoteAction(id: UUID(), title: "F", prompt: "retry", status: .failed)
        failed.error = "boom"
        failed.linkID = UUID()
        failed.startedAt = .now
        harness.state.seedNotesForTesting([HerdrNote(id: id, body: "n", actions: [started, failed])])

        await harness.state.runAction(started.id, in: id, model: harness.model)
        #expect(harness.spawner.sendCalls.isEmpty)
        #expect(harness.state.note(id: id)?.actions[0] == started)

        let priorLinkID = failed.linkID
        await harness.state.runAction(failed.id, in: id, model: harness.model)
        let updated = try #require(harness.state.note(id: id))
        #expect(updated.actions[1].status == .started)
        #expect(updated.actions[1].error == nil)
        #expect(updated.actions[1].linkID != priorLinkID)
        #expect(updated.actions[1].linkID == updated.links.first?.id)
        #expect(harness.spawner.sendCalls.count == 1)
        #expect(harness.state.noteStatus[id] == "Session started — click ↗ to open")
    }

    @Test("Restore merges stored notes after in-memory ones and in-memory wins on collision")
    func restoreMergesAfterInMemoryNotes() async throws {
        let suiteName = "HerdrHudNotesStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        let sharedID = UUID()
        let storedOnlyID = UUID()
        try HerdrNotesSnapshot(notes: [
            HerdrNote(id: sharedID, title: "stored"),
            HerdrNote(id: storedOnlyID, title: "only-stored"),
        ]).save(to: url)

        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"], userDefaults: defaults)
        let ai = FakeNoteAIRunner()
        let pane = HerdrPane(paneID: "pane", terminalID: "terminal", workspaceID: "workspace", tabID: "tab", focused: false, agentStatus: .unknown, revision: 0, cwd: nil, foregroundCWD: nil, label: "Notes", title: nil, agent: nil, displayAgent: nil, terminalTitle: nil, terminalTitleStripped: nil).stamped(machineID: model.machines.first?.id ?? "demo")
        let spawner = FakeNoteSessionSpawner(spawnMode: .succeed(pane))
        let state = HerdrHudNotesState(userDefaults: defaults, agentSettings: AgentModelSettingsStore(defaults: defaults), promptSettings: HerdrPromptSettingsStore(defaults: defaults), persistenceURL: url, aiRunner: ai, sessionSpawner: spawner, hoverGrace: .zero, hoverDelay: .zero, saveDelay: .zero)

        state.seedNotesForTesting([HerdrNote(id: sharedID, title: "memory")])
        let created = state.createNote()
        await state.waitForPersistenceRestoreForTesting()

        #expect(state.notes.map(\.id) == [created, sharedID, storedOnlyID])
        #expect(state.note(id: sharedID)?.title == "memory")
        #expect(state.layout == .card)
    }

    private struct Harness { let model: HerdrAppModel; let state: HerdrHudNotesState; let ai: FakeNoteAIRunner; let spawner: FakeNoteSessionSpawner; let agentSettings: AgentModelSettingsStore }

    private func makeHarness() async -> Harness {
        let suiteName = "HerdrHudNotesStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"], userDefaults: defaults)
        let ai = FakeNoteAIRunner()
        let pane = HerdrPane(paneID: "pane", terminalID: "terminal", workspaceID: "workspace", tabID: "tab", focused: false, agentStatus: .unknown, revision: 0, cwd: nil, foregroundCWD: nil, label: "Notes", title: nil, agent: nil, displayAgent: nil, terminalTitle: nil, terminalTitleStripped: nil).stamped(machineID: model.machines.first?.id ?? "demo")
        let spawner = FakeNoteSessionSpawner(spawnMode: .succeed(pane))
        let agentSettings = AgentModelSettingsStore(defaults: defaults)
        let state = HerdrHudNotesState(userDefaults: defaults, agentSettings: agentSettings, promptSettings: HerdrPromptSettingsStore(defaults: defaults), persistenceURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json"), aiRunner: ai, sessionSpawner: spawner, hoverGrace: .zero, hoverDelay: .zero, saveDelay: .zero)
        await state.waitForPersistenceRestoreForTesting()
        return Harness(model: model, state: state, ai: ai, spawner: spawner, agentSettings: agentSettings)
    }
}
