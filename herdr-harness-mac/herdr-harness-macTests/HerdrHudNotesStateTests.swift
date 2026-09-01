import Foundation
import Testing
@testable import herdr_harness_mac

@MainActor
final class FakeNoteAIRunner: HerdrNoteAIRunner {
    struct Call { let prompt: String; let machineID: String; let mode: HeadlessAgentRunMode }
    enum Mode { case succeed(String), throwing(any Error), hanging }
    var mode: Mode = .succeed("")
    private(set) var calls: [Call] = []

    func run(prompt: String, machineID: String, mode: HeadlessAgentRunMode, model: String?, thinkingLevel: String?, systemPrompt: String?, deadline: Duration, appModel: HerdrAppModel) async throws -> String {
        calls.append(Call(prompt: prompt, machineID: machineID, mode: mode))
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
        harness.ai.mode = .succeed(#"{"summary":"s","actions":[{"title":"A","prompt":"do a"},{"title":"B","prompt":"do b"}]}"#)
        await harness.state.planActions(id, model: harness.model)
        #expect(harness.state.note(id: id)?.actions.count == 2)
        #expect(harness.state.note(id: id)?.aiSummary == "s")
        #expect(harness.state.note(id: id)?.actions.allSatisfy { $0.status == .ready } == true)
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

    private struct Harness { let model: HerdrAppModel; let state: HerdrHudNotesState; let ai: FakeNoteAIRunner; let spawner: FakeNoteSessionSpawner }

    private func makeHarness() async -> Harness {
        let suiteName = "HerdrHudNotesStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"], userDefaults: defaults)
        let ai = FakeNoteAIRunner()
        let pane = HerdrPane(paneID: "pane", terminalID: "terminal", workspaceID: "workspace", tabID: "tab", focused: false, agentStatus: .unknown, revision: 0, cwd: nil, foregroundCWD: nil, label: "Notes", title: nil, agent: nil, displayAgent: nil, terminalTitle: nil, terminalTitleStripped: nil).stamped(machineID: model.machines.first?.id ?? "demo")
        let spawner = FakeNoteSessionSpawner(spawnMode: .succeed(pane))
        let state = HerdrHudNotesState(userDefaults: defaults, agentSettings: AgentModelSettingsStore(defaults: defaults), promptSettings: HerdrPromptSettingsStore(defaults: defaults), persistenceURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json"), aiRunner: ai, sessionSpawner: spawner, hoverGrace: .zero, hoverDelay: .zero, saveDelay: .zero)
        await state.waitForPersistenceRestoreForTesting()
        return Harness(model: model, state: state, ai: ai, spawner: spawner)
    }
}
