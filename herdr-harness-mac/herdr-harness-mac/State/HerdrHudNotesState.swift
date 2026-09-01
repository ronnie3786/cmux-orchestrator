import AppKit
import Foundation
import Observation

// MARK: - AI runner seam

@MainActor
protocol HerdrNoteAIRunner {
    func run(
        prompt: String,
        machineID: String,
        mode: HeadlessAgentRunMode,
        model: String?,
        thinkingLevel: String?,
        systemPrompt: String?,
        deadline: Duration,
        appModel: HerdrAppModel
    ) async throws -> String
}

enum HerdrNoteAIPrompts {
    static let noToolsCharter = "You are a text rewriting assistant. Never call tools; the topology snapshot is irrelevant to this task. Reply with plain text only."
}

enum HerdrNoteAIError: LocalizedError {
    case startFailed(String)
    case runFailed(String)
    case emptyResponse
    case timedOut(Int)
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .startFailed(reason), let .runFailed(reason): reason
        case .emptyResponse: "The response was empty."
        case let .timedOut(seconds): "Timed out after \(seconds)s."
        case .cancelled: "Cancelled."
        }
    }
}

@MainActor
struct HerdrLiveNoteAIRunner: HerdrNoteAIRunner {
    func run(
        prompt: String,
        machineID: String,
        mode: HeadlessAgentRunMode,
        model: String?,
        thinkingLevel: String?,
        systemPrompt: String?,
        deadline: Duration,
        appModel: HerdrAppModel
    ) async throws -> String {
        let controller = HeadlessAgentController()
        await controller.submit(
            prompt: prompt,
            machineID: machineID,
            mode: mode,
            agentModel: model,
            thinkingLevel: thinkingLevel,
            systemPrompt: systemPrompt,
            model: appModel
        )
        guard controller.run != nil else {
            throw HerdrNoteAIError.startFailed(controller.errorMessage ?? "Couldn't reach the machine")
        }
        let clock = ContinuousClock()
        let deadlineInstant = clock.now.advanced(by: deadline)
        while controller.isRunning {
            if Task.isCancelled {
                await Task { @MainActor in await controller.cancel(model: appModel) }.value
                throw HerdrNoteAIError.cancelled
            }
            if clock.now >= deadlineInstant {
                await controller.cancel(model: appModel)
                throw HerdrNoteAIError.timedOut(Int(deadline.components.seconds))
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let run = controller.run else {
            throw HerdrNoteAIError.startFailed(controller.errorMessage ?? "Couldn't reach the machine")
        }
        switch run.status {
        case .completed, .promoted:
            let response = (run.response ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !response.isEmpty else { throw HerdrNoteAIError.emptyResponse }
            return response
        case .failed, .cancelled, .queued, .running:
            throw HerdrNoteAIError.runFailed(run.error ?? run.status.label)
        }
    }
}

// MARK: - Live session spawner seam

@MainActor
protocol HerdrNoteSessionSpawner {
    func spawn(machineID: String, label: String, workspaceLabel: String, tabLabel: String, appModel: HerdrAppModel) async throws -> HerdrPane
    func sendPrompt(to pane: HerdrPane, text: String, appModel: HerdrAppModel) async throws
}

@MainActor
struct HerdrLiveNoteSessionSpawner: HerdrNoteSessionSpawner {
    func spawn(machineID: String, label: String, workspaceLabel: String, tabLabel: String, appModel: HerdrAppModel) async throws -> HerdrPane {
        try await appModel.createLinkedQuickPiSession(
            machineID: machineID,
            label: label,
            workspaceLabel: workspaceLabel,
            tabLabel: tabLabel
        )
    }

    func sendPrompt(to pane: HerdrPane, text: String, appModel: HerdrAppModel) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(25))
        while true {
            try Task.checkCancellation()
            do {
                try await appModel.sendPiConversationPrompt(text, disposition: .prompt, to: pane)
                return
            } catch {
                guard Self.isRetryable(error), clock.now < deadline else { throw error }
                try await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private static func isRetryable(_ error: any Error) -> Bool {
        if let apiError = error as? APIError, case let .server(status, _) = apiError {
            return status >= 500 || status == 409
        }
        if let urlError = error as? URLError { return urlError.code != .cancelled }
        return false
    }
}

// MARK: - Notes state

@MainActor
@Observable
final class HerdrHudNotesState {
    typealias Layout = HerdrHudPlacement.NotesLayout

    enum Activity: Equatable {
        case cleaning
        case planning
        case starting(UUID)
    }

    private enum MachineResolution {
        case machineID(String)
        case noMachine
        case notConnected
    }

    private(set) var notes: [HerdrNote] = []
    private(set) var openNoteID: UUID?
    private(set) var isHovering = false
    var isHudExpanded = false {
        didSet {
            guard isHudExpanded != oldValue else { return }
            refreshLayout()
        }
    }
    private(set) var activities: [UUID: Activity] = [:]
    private(set) var noteErrors: [UUID: String] = [:]
    private(set) var noteStatus: [UUID: String] = [:]
    private(set) var revealRevision: [UUID: Int] = [:]
    private(set) var celebratingNoteID: UUID?
    private(set) var layout: Layout = .hidden

    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let agentSettings: AgentModelSettingsStore
    @ObservationIgnored private let promptSettings: HerdrPromptSettingsStore
    @ObservationIgnored private let store: HerdrNotesStore
    @ObservationIgnored private let aiRunner: any HerdrNoteAIRunner
    @ObservationIgnored private let sessionSpawner: any HerdrNoteSessionSpawner
    @ObservationIgnored private let hoverGrace: Duration
    @ObservationIgnored private let hoverDelay: Duration
    @ObservationIgnored private let saveDelay: Duration
    @ObservationIgnored private var hasRestored = false
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var activityTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var celebrationTask: Task<Void, Never>?
    @ObservationIgnored private var noteStatusTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored nonisolated(unsafe) private var terminationObserver: NSObjectProtocol?

    init(
        userDefaults: UserDefaults = .standard,
        agentSettings: AgentModelSettingsStore,
        promptSettings: HerdrPromptSettingsStore,
        persistenceURL: URL? = nil,
        aiRunner: any HerdrNoteAIRunner = HerdrLiveNoteAIRunner(),
        sessionSpawner: any HerdrNoteSessionSpawner = HerdrLiveNoteSessionSpawner(),
        hoverGrace: Duration = .milliseconds(350),
        hoverDelay: Duration = .milliseconds(120),
        saveDelay: Duration = .milliseconds(500)
    ) {
        self.userDefaults = userDefaults
        self.agentSettings = agentSettings
        self.promptSettings = promptSettings
        store = HerdrNotesStore(fileURL: persistenceURL ?? HerdrNotesStore.defaultFileURL())
        self.aiRunner = aiRunner
        self.sessionSpawner = sessionSpawner
        self.hoverGrace = hoverGrace
        self.hoverDelay = hoverDelay
        self.saveDelay = saveDelay
        let store = self.store
        restoreTask = Task { [weak self, store] in
            let snapshot = await store.load()
            guard !Task.isCancelled else { return }
            self?.restore(snapshot)
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.hasRestored else { return }
                try? HerdrNotesSnapshot(notes: self.notes).save(to: self.store.fileURL)
            }
        }
    }

    deinit {
        restoreTask?.cancel()
        hoverTask?.cancel()
        celebrationTask?.cancel()
        for task in activityTasks.values { task.cancel() }
        for task in noteStatusTasks.values { task.cancel() }
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    func note(id: UUID) -> HerdrNote? { notes.first { $0.id == id } }
    func isBusy(_ id: UUID) -> Bool { activities[id] != nil }

    @discardableResult
    func createNote(color: HerdrNoteColor = .yellow) -> UUID {
        let note = HerdrNote(color: color)
        notes.insert(note, at: 0)
        if openNoteID != note.id { openNoteID = note.id }
        refreshLayout()
        schedulePersistedSave()
        return note.id
    }

    func updateTitle(_ title: String, for id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].title != title else { return }
        notes[index].title = title
        notes[index].updatedAt = .now
        schedulePersistedSave()
    }

    func updateBody(_ body: String, for id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let capped = String(body.prefix(HerdrNotesSnapshot.maximumBodyLength))
        guard notes[index].body != capped else { return }
        notes[index].body = capped
        notes[index].updatedAt = .now
        let nextError = capped.count < body.count ? "Notes are limited to 20,000 characters." : nil
        if noteErrors[id] != nextError { noteErrors[id] = nextError }
        schedulePersistedSave()
    }

    func setColor(_ color: HerdrNoteColor, for id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].color != color else { return }
        notes[index].color = color
        schedulePersistedSave()
    }

    func deleteNote(_ id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        cancelActivity(id)
        notes.remove(at: index)
        if activities[id] != nil { activities[id] = nil }
        if noteErrors[id] != nil { noteErrors[id] = nil }
        if noteStatus[id] != nil { noteStatus[id] = nil }
        if revealRevision[id] != nil { revealRevision[id] = nil }
        noteStatusTasks[id]?.cancel()
        noteStatusTasks[id] = nil
        if celebratingNoteID == id { celebratingNoteID = nil }
        if openNoteID == id { openNoteID = nil }
        refreshLayout()
        flushPersistence()
    }

    func openNote(_ id: UUID) {
        guard notes.contains(where: { $0.id == id }) else { return }
        if openNoteID != id { openNoteID = id }
        if let index = notes.firstIndex(where: { $0.id == id }), index != 0 {
            let moved = notes.remove(at: index)
            notes.insert(moved, at: 0)
        }
        refreshLayout()
        schedulePersistedSave()
    }

    func closeNote() {
        guard openNoteID != nil else { return }
        openNoteID = nil
        refreshLayout()
        flushPersistence()
    }

    func setHovering(_ hovering: Bool) {
        guard hovering != isHovering || hoverTask != nil else { return }
        hoverTask?.cancel()
        let delay = hovering ? hoverDelay : hoverGrace
        hoverTask = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.hoverTask = nil
            guard self.isHovering != hovering else { return }
            self.isHovering = hovering
            self.refreshLayout()
        }
    }

    func undoAI(_ id: UUID) {
        guard !isBusy(id), let index = notes.firstIndex(where: { $0.id == id }), let previous = notes[index].previousVersion else { return }
        notes[index].title = previous.title
        notes[index].body = previous.body
        notes[index].previousVersion = nil
        bumpRevealRevision(id)
        schedulePersistedSave()
    }

    func cancelActivity(_ id: UUID) { activityTasks[id]?.cancel() }

    func cleanUp(_ id: UUID, model: HerdrAppModel) async {
        guard !isBusy(id), let index = notes.firstIndex(where: { $0.id == id }) else { return }
        if noteErrors[id] != nil { noteErrors[id] = nil }
        let note = notes[index]
        let noteText = Self.composeNoteText(note)
        let shouldSnapshot = note.previousVersion == nil || note.lastCleanedAt == nil || note.updatedAt > note.lastCleanedAt!
        activities[id] = .cleaning
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.finishActivity(id) }
            let machineID: String
            switch self.resolveMachine(model: model) {
            case .noMachine: self.setError("No machine is available", for: id); return
            case .notConnected: self.setError("This machine is not connected.", for: id); return
            case let .machineID(value): machineID = value
            }
            do {
                let systemPrompt = await model.supportsPromptOverrides(machineID: machineID) ? HerdrNoteAIPrompts.noToolsCharter : nil
                let prompt = HerdrPromptTemplate.render(self.promptSettings.text(for: .notesCleanup), values: ["note": HerdrNoteAIParsing.fenceSafe(noteText)])
                let response = try await self.aiRunner.run(prompt: prompt, machineID: machineID, mode: .ask, model: self.agentSettings.effectiveNotesModel, thinkingLevel: self.agentSettings.notesThinkingLevel.rawValue, systemPrompt: systemPrompt, deadline: .seconds(60), appModel: model)
                guard let freshIndex = self.notes.firstIndex(where: { $0.id == id }) else { return }
                guard let cleanup = HerdrNoteAIParsing.cleanup(response) else { self.setError("Couldn't tidy this note — try again.", for: id); return }
                if shouldSnapshot {
                    self.notes[freshIndex].previousVersion = HerdrNoteVersion(title: self.notes[freshIndex].title, body: self.notes[freshIndex].body, replacedAt: .now)
                }
                if let title = cleanup.title { self.notes[freshIndex].title = title }
                self.notes[freshIndex].body = cleanup.body
                let now = Date.now
                self.notes[freshIndex].lastCleanedAt = now
                self.notes[freshIndex].updatedAt = now
                self.bumpRevealRevision(id)
                self.startCelebration(id)
                self.schedulePersistedSave()
            } catch {
                guard self.notes.contains(where: { $0.id == id }) else { return }
                self.setError(error.localizedDescription, for: id)
            }
        }
        activityTasks[id] = task
        await task.value
    }

    func planActions(_ id: UUID, model: HerdrAppModel) async {
        guard !isBusy(id), let note = notes.first(where: { $0.id == id }) else { return }
        if noteErrors[id] != nil { noteErrors[id] = nil }
        let noteText = Self.composeNoteText(note)
        activities[id] = .planning
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.finishActivity(id) }
            let machineID: String
            switch self.resolveMachine(model: model) {
            case .noMachine: self.setError("No machine is available", for: id); return
            case .notConnected: self.setError("This machine is not connected.", for: id); return
            case let .machineID(value): machineID = value
            }
            do {
                let prompt = HerdrPromptTemplate.render(self.promptSettings.text(for: .notesSmartActions), values: ["note": HerdrNoteAIParsing.fenceSafe(noteText)])
                let response = try await self.aiRunner.run(prompt: prompt, machineID: machineID, mode: .ask, model: self.agentSettings.effectiveNotesModel, thinkingLevel: self.agentSettings.notesThinkingLevel.rawValue, systemPrompt: nil, deadline: .seconds(150), appModel: model)
                guard let freshIndex = self.notes.firstIndex(where: { $0.id == id }) else { return }
                guard let parsed = HerdrNoteAIParsing.smartActions(response) else {
                    self.setError("Couldn't work out actions for this note.", for: id)
                    return
                }
                self.notes[freshIndex].actions = parsed.actions.map { HerdrNoteAction(id: UUID(), title: $0.title, prompt: $0.prompt) }
                self.notes[freshIndex].aiSummary = parsed.summary
                self.schedulePersistedSave()
            } catch {
                guard self.notes.contains(where: { $0.id == id }) else { return }
                self.setError(error.localizedDescription, for: id)
            }
        }
        activityTasks[id] = task
        await task.value
    }

    func runAction(_ actionID: UUID, in noteID: UUID, model: HerdrAppModel) async {
        guard !isBusy(noteID), let noteIndex = notes.firstIndex(where: { $0.id == noteID }), let actionIndex = notes[noteIndex].actions.firstIndex(where: { $0.id == actionID }) else { return }
        guard notes[noteIndex].actions[actionIndex].status == .ready || notes[noteIndex].actions[actionIndex].status == .failed else { return }
        if noteErrors[noteID] != nil { noteErrors[noteID] = nil }
        let note = notes[noteIndex]
        let action = note.actions[actionIndex]
        let noteText = Self.composeNoteText(note)
        let displayTitle = note.displayTitle
        notes[noteIndex].actions[actionIndex].status = .starting
        notes[noteIndex].actions[actionIndex].error = nil
        notes[noteIndex].actions[actionIndex].linkID = nil
        activities[noteID] = .starting(actionID)
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.finishActivity(noteID) }
            @MainActor func failAction(_ message: String) {
                guard let index = self.notes.firstIndex(where: { $0.id == noteID }), let actionIndex = self.notes[index].actions.firstIndex(where: { $0.id == actionID }) else { return }
                self.notes[index].actions[actionIndex].status = .failed
                self.notes[index].actions[actionIndex].error = message
            }
            let machineID: String
            switch self.resolveMachine(model: model) {
            case .noMachine: failAction("No machine is available"); return
            case .notConnected: failAction("This machine is not connected."); return
            case let .machineID(value): machineID = value
            }
            let tabLabel = String(String.UnicodeScalarView(displayTitle.unicodeScalars.prefix(120)))
            let label = String(String.UnicodeScalarView(("note · " + displayTitle).unicodeScalars.prefix(120)))
            do {
                let pane = try await self.sessionSpawner.spawn(machineID: machineID, label: label, workspaceLabel: "Notes", tabLabel: tabLabel, appModel: model)
                guard let freshIndex = self.notes.firstIndex(where: { $0.id == noteID }), let freshActionIndex = self.notes[freshIndex].actions.firstIndex(where: { $0.id == actionID }) else { return }
                let link = HerdrNoteLink(id: UUID(), paneID: pane.id, machineID: machineID, title: pane.displayTitle.isEmpty ? action.title : pane.displayTitle, createdAt: .now, actionTitle: action.title)
                self.notes[freshIndex].links.append(link)
                self.notes[freshIndex].actions[freshActionIndex].linkID = link.id
                self.notes[freshIndex].actions[freshActionIndex].status = .started
                self.notes[freshIndex].actions[freshActionIndex].startedAt = .now
                self.schedulePersistedSave()
                if self.noteStatus[noteID] != "Session open — handing over the task…" { self.noteStatus[noteID] = "Session open — handing over the task…" }
                let renderedPrompt = HerdrPromptTemplate.render(self.promptSettings.text(for: .notesTakeAction), values: ["action": action.prompt, "note": HerdrNoteAIParsing.fenceSafe(noteText)])
                do {
                    try await self.sessionSpawner.sendPrompt(to: pane, text: renderedPrompt, appModel: model)
                    self.setTransientNoteStatus("Session started — click ↗ to open", for: noteID)
                } catch {
                    guard let latestIndex = self.notes.firstIndex(where: { $0.id == noteID }), let latestActionIndex = self.notes[latestIndex].actions.firstIndex(where: { $0.id == actionID }) else { return }
                    self.notes[latestIndex].actions[latestActionIndex].error = "Session opened, but the task didn't send: \(error.localizedDescription)"
                    if self.noteStatus[noteID] != nil { self.noteStatus[noteID] = nil }
                    model.copyToPasteboard(renderedPrompt)
                }
            } catch {
                failAction(error.localizedDescription)
            }
        }
        activityTasks[noteID] = task
        await task.value
    }

    private func refreshLayout() {
        let next: Layout
        if let openNoteID, notes.contains(where: { $0.id == openNoteID }) {
            next = .card
        } else if isHovering || isHudExpanded {
            next = .rows(count: notes.count)
        } else if notes.isEmpty {
            next = .hidden
        } else {
            next = .compact(count: notes.count)
        }
        if next != layout { layout = next }
    }

    private static func composeNoteText(_ note: HerdrNote) -> String {
        note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? note.body : "Title: \(note.title)\n\n\(note.body)"
    }

    private func resolveMachine(model: HerdrAppModel) -> MachineResolution {
        let storedID = userDefaults.string(forKey: HerdrHudSession.machineIDDefaultsKey)
        let machineID = storedID.flatMap { candidate in model.machines.contains { $0.id == candidate } ? candidate : nil } ?? model.machines.first?.id
        guard let machineID else { return .noMachine }
        guard model.canControl(machineID: machineID) else { return .notConnected }
        return .machineID(machineID)
    }

    private func setError(_ text: String, for id: UUID) {
        if noteErrors[id] != text { noteErrors[id] = text }
    }

    private func finishActivity(_ id: UUID) {
        if activities[id] != nil { activities[id] = nil }
        activityTasks[id] = nil
    }

    private func bumpRevealRevision(_ id: UUID) { revealRevision[id, default: 0] += 1 }

    private func startCelebration(_ id: UUID) {
        celebrationTask?.cancel()
        if celebratingNoteID != id { celebratingNoteID = id }
        celebrationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1_200))
            guard !Task.isCancelled, let self, self.celebratingNoteID == id else { return }
            self.celebratingNoteID = nil
        }
    }

    private func setTransientNoteStatus(_ text: String, for id: UUID) {
        noteStatusTasks[id]?.cancel()
        if noteStatus[id] != text { noteStatus[id] = text }
        noteStatusTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            if self.noteStatus[id] == text { self.noteStatus[id] = nil }
            self.noteStatusTasks[id] = nil
        }
    }

    private func restore(_ snapshot: HerdrNotesSnapshot?) {
        if let snapshot {
            let existingIDs = Set(notes.map(\.id))
            let restored = snapshot.notes.filter { !existingIDs.contains($0.id) }.map { note -> HerdrNote in
                var copy = note
                for i in copy.actions.indices where copy.actions[i].status == .starting {
                    copy.actions[i].status = .failed
                    copy.actions[i].error = "Interrupted before the session started."
                }
                return copy
            }
            if !restored.isEmpty { notes += restored }
        }
        hasRestored = true
        refreshLayout()
        schedulePersistedSave()
    }

    private func schedulePersistedSave() {
        guard hasRestored else { return }
        let snapshot = HerdrNotesSnapshot(notes: notes)
        Task { [store, saveDelay] in await store.scheduleSave(snapshot, delay: saveDelay) }
    }

    private func flushPersistence() {
        guard hasRestored else { return }
        let snapshot = HerdrNotesSnapshot(notes: notes)
        Task { [store] in
            await store.scheduleSave(snapshot, delay: .zero)
            await store.flush()
        }
    }

    #if DEBUG
    func waitForPersistenceRestoreForTesting() async { await restoreTask?.value }

    func seedNotesForTesting(_ seeded: [HerdrNote]) {
        guard notes != seeded else { return }
        notes = seeded
        refreshLayout()
    }
    #endif
}
