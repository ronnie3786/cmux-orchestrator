import SwiftUI

@MainActor
private final class TerminalSessionScratch {
    var lastActivityAt: Date?
    var lastSnapshotText: String?
    var lastSnapshotRevision = 0
}

@MainActor
private final class PendingTerminalCommit {
    var grid: TerminalGrid?
    var sequence = 0
    var coalescer = TerminalFrameCoalescer()
    var flushTask: Task<Void, Never>?
}

@MainActor
final class PiInteractionResponder {
    func respond(
        to interaction: PiPendingInteraction,
        response: PiInteractionResponseBody,
        store: PiConversationStore,
        model: HerdrAppModel,
        pane: HerdrPane
    ) async -> Bool {
        await store.respond(to: interaction, response: response, model: model, pane: pane)
    }
}

/// One pane's session: header, mode content, and the terminal's dual-feed
/// lifecycle (SSE frames + 850 ms snapshot poll arbitrated by
/// `TerminalRefreshPolicy`).
///
/// Mac differences from iOS: `PaneSessionHeader` is mounted for real (there is
/// no per-pane navigation bar to carry the title), the tab-bar/size-class
/// chrome is gone, and the terminal is a focusable keyboard surface — see
/// `TerminalKeyboardRouter`. The follow loop is no longer gated on
/// `scenePhase`: a Mac window that is behind another app is still a window the
/// user is watching, and tearing the stream down every time it loses key status
/// would make it flap.
struct PaneSessionView: View {
    @Bindable var model: HerdrAppModel
    let pane: HerdrPane
    /// iOS hid the app tab bar on this screen. The Mac has no tab bar; the flag
    /// survives only so existing call sites keep compiling.
    var hidesAppTabBar = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.herdrFontScale) private var fontScale
    @FocusState private var isTerminalFocused: Bool
    @State private var keyboardRouter = TerminalKeyboardRouter()
    @State private var output = "Connecting to terminal…"
    @State private var snapshotRevision = 0
    @State private var snapshotFrameSequence = 0
    @State private var snapshotRequestSequence = 0
    @State private var frameSequence = 0
    @State private var terminalGrid = TerminalGrid(columns: 100, rows: 32)
    @State private var renderedOutput: AttributedString?
    @State private var terminalSource: TerminalSource = .connecting
    @State private var scratch = TerminalSessionScratch()
    @State private var isFollowing = true
    @State private var manualRefreshGeneration = 0
    @State private var manualRefreshPaneID: String?
    @State private var isManuallyRefreshing = false
    @State private var outputError: String?
    @State private var selectedMode: PaneDetailMode = .terminal
    @State private var piConversationStore = PiConversationStore()
    @State private var piInteractionResponder = PiInteractionResponder()
    @State private var didAutoSelectChat = false
    @State private var composerDraft = ""
    @State private var composerAttachments: [TerminalAttachment] = []
    @State private var composerFocusRequest = 0

    var body: some View {
        ZStack {
            HerdrBackground()

            VStack(spacing: 0) {
                PaneSessionHeader(model: model, pane: currentPane, store: piConversationStore)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                Rectangle()
                    .fill(HerdrTheme.surface)
                    .frame(height: 1)

                modeContent
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: selectedMode)
        }
        .navigationTitle(currentPane.displayTitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                PaneActionsMenu(model: model, pane: currentPane, selectedMode: modeSelection)
            }
        }
        .task(id: followTaskID) {
            await followOutput()
        }
        .task(id: manualRefreshTaskID) {
            guard selectedMode == .terminal,
                  manualRefreshGeneration > 0,
                  manualRefreshPaneID == currentPane.id
            else { return }
            isManuallyRefreshing = true
            defer { isManuallyRefreshing = false }
            await refreshOutput(forceSnapshot: terminalSource != .stream)
        }
        // View ▸ Focus Chat (⌘2) / Focus Terminal (⌘3). The shell cannot set
        // the mode itself — `selectedMode` belongs to whichever session is
        // mounted — so the commands post and the session listens.
        .task {
            for await notification in NotificationCenter.default.notifications(
                named: .herdrFocusPaneMode
            ) {
                guard let mode = notification.object as? PaneDetailMode else { continue }
                focus(mode: mode)
            }
        }
        .task(id: piChatTaskID) {
            guard selectedMode == .chat,
                  currentPane.supportsPiSemanticChat
            else { return }
            await piConversationStore.follow(model: model, pane: currentPane)
        }
        .onAppear {
            autoSelectChatIfNeeded()
        }
        .onChange(of: currentPane.supportsPiSemanticChat) { _, supportsChat in
            if supportsChat {
                autoSelectChatIfNeeded()
            } else if selectedMode == .chat {
                selectedMode = .terminal
            }
        }
        .onChange(of: fontScale) { _, newScale in
            if terminalSource == .stream {
                renderedOutput = terminalGrid.attributedText(scale: newScale)
            }
        }
        .onChange(of: pane.id) { oldPaneID, newPaneID in
            guard oldPaneID != newPaneID else { return }
            discardComposerState()
            piConversationStore.reset()
            didAutoSelectChat = false
            if currentPane.supportsPiSemanticChat {
                autoSelectChatIfNeeded()
            } else {
                selectedMode = .terminal
            }
        }
        .onDisappear {
            composerAttachments.forEach { $0.removeSourceFileIfOwned() }
            keyboardRouter.discardPendingInput()
        }
        .overlay(alignment: .top) {
            if let outputError {
                Label(outputError, systemImage: "exclamationmark.triangle.fill")
                    .herdrFont(.caption, weight: .bold)
                    .foregroundStyle(HerdrTheme.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(HerdrTheme.alert, in: Capsule())
                    .padding(.top, 8)
                    .accessibilityLabel("Terminal error: \(outputError)")
            }
        }
    }

    private var currentPane: HerdrPane {
        model.pane(id: pane.id) ?? pane
    }

    private var modeSelection: Binding<PaneDetailMode> {
        Binding(
            get: { selectedMode },
            set: { mode in
                selectedMode = mode
                if mode == .terminal { didAutoSelectChat = true }
            }
        )
    }

    @ViewBuilder
    private var modeContent: some View {
        switch selectedMode {
        case .chat:
            if currentPane.supportsPiSemanticChat, let workspace {
                PiChatView(
                    model: model,
                    store: piConversationStore,
                    paneID: currentPane.id,
                    interactionResponseAvailable: currentPane.piSemantic?.capabilities.interactionResponse ?? false,
                    composerPane: currentPane,
                    workspace: workspace,
                    draft: $composerDraft,
                    attachments: $composerAttachments,
                    focusRequest: composerFocusRequest,
                    interactionResponder: piInteractionResponder
                )
                    .equatable()
                    .transition(.opacity)
            } else {
                unavailableMode("Chat", systemImage: "bubble.left.and.bubble.right")
            }
        case .terminal:
            terminalContent
        case .git:
            if let workspace {
                WorkspaceGitView(
                    workspace: workspace,
                    loadStatus: { try await model.fetchGitStatus(for: workspace) },
                    loadDiff: { file, section in
                        try await model.fetchGitDiff(for: workspace, file: file, section: section)
                    },
                    stageFile: { file in try await model.stageGitFile(file, in: workspace) },
                    unstageFile: { file in try await model.unstageGitFile(file, in: workspace) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                unavailableMode("Git", systemImage: "point.3.connected.trianglepath.dotted")
            }
        case .skills:
            if let workspace {
                WorkspaceSkillsView(
                    workspace: workspace,
                    loadSkills: { try await model.fetchSkills(for: workspace) },
                    selectToken: insertComposerToken
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                unavailableMode("Skills", systemImage: "wand.and.stars")
            }
        }
    }

    private var terminalContent: some View {
        VStack(spacing: 0) {
            PaneTerminalView(
                pane: currentPane,
                output: output,
                attributedOutput: renderedOutput,
                revision: terminalSource == .stream ? frameSequence : snapshotRevision,
                dimensions: terminalSource == .stream ? "\(terminalGrid.columns)×\(terminalGrid.rows)" : nil,
                source: terminalSource,
                isFollowing: $isFollowing,
                isRefreshing: isManuallyRefreshing,
                isKeyboardFocused: isTerminalFocused,
                refresh: manualRefresh
            )
            .id(currentPane.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .terminalKeyboardRouting(
                router: keyboardRouter,
                model: model,
                pane: currentPane,
                isFocused: $isTerminalFocused
            )

            if let workspace {
                PromptComposerView(
                    model: model,
                    pane: currentPane,
                    workspace: workspace,
                    draft: $composerDraft,
                    attachments: $composerAttachments,
                    focusRequest: composerFocusRequest
                )
                .equatable()
                .id(currentPane.id)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 10)
            }
        }
    }

    private var workspace: HerdrWorkspace? {
        model.workspace(containing: currentPane)
    }

    private func unavailableMode(_ name: String, systemImage: String) -> some View {
        ContentUnavailableView(
            "\(name) unavailable",
            systemImage: systemImage,
            description: Text("The pane is no longer attached to a workspace.")
        )
        .foregroundStyle(HerdrTheme.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func insertComposerToken(_ token: String) {
        let trimmed = composerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        composerDraft = trimmed.isEmpty ? token : "\(trimmed) \(token)"
        selectedMode = .terminal
        composerFocusRequest &+= 1
    }

    /// Switches mode *and* puts the caret where the command's name promises:
    /// "Focus Chat" focuses the composer, "Focus Terminal" focuses the keyboard
    /// surface. Chat is refused on a pane that has no Pi session — the mode
    /// would only render the unavailable placeholder.
    private func focus(mode: PaneDetailMode) {
        switch mode {
        case .chat:
            guard currentPane.supportsPiSemanticChat else { return }
            didAutoSelectChat = true
            selectedMode = .chat
            isTerminalFocused = false
            composerFocusRequest &+= 1
        case .terminal:
            didAutoSelectChat = true
            selectedMode = .terminal
            isTerminalFocused = true
        default:
            selectedMode = mode
        }
    }

    private func discardComposerState() {
        composerAttachments.forEach { $0.removeSourceFileIfOwned() }
        composerAttachments = []
        composerDraft = ""
        composerFocusRequest = 0
    }

    private func autoSelectChatIfNeeded() {
        guard !didAutoSelectChat,
              selectedMode == .terminal,
              currentPane.supportsPiSemanticChat
        else { return }
        didAutoSelectChat = true
        selectedMode = .chat
    }

    private var followTaskID: String {
        "\(pane.id):\(model.connectionGeneration):terminal=\(selectedMode == .terminal)"
    }

    private var manualRefreshTaskID: String {
        "\(followTaskID):refresh:\(manualRefreshGeneration)"
    }

    private var piChatTaskID: String {
        "\(pane.id):pi-chat:\(model.connectionGeneration):\(selectedMode.rawValue)"
    }

    private var isStreamHealthy: Bool {
        terminalSource == .stream && !TerminalRefreshPolicy.isStreamStale(
            lastStreamActivityAt: scratch.lastActivityAt
        )
    }

    private func followOutput() async {
        guard selectedMode == .terminal else { return }
        resetTerminal()
        await refreshOutput(forceSnapshot: true)
        if model.isDemoMode { return }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await followFrames() }
            group.addTask { await pollSnapshots() }
            await group.waitForAll()
        }
    }

    private func followFrames() async {
        let clock = ContinuousClock()
        var retryDelay = 0.65
        let pending = PendingTerminalCommit()
        while !Task.isCancelled {
            do {
                guard let events = await model.terminalEvents(for: currentPane) else {
                    if terminalSource != .snapshot {
                        displayCachedSnapshot()
                        terminalSource = .snapshot
                        if renderedOutput != nil { renderedOutput = nil }
                    }
                    retryDelay = min(retryDelay * 1.7, 5)
                    try await Task.sleep(for: .seconds(retryDelay))
                    continue
                }

                var working = terminalGrid
                defer { pending.flushTask?.cancel() }
                defer { HerdrPerfDiagnostics.streamBacklog.reset(.terminal) }
                for try await event in events {
                    try Task.checkCancellation()
                    HerdrPerfDiagnostics.streamBacklog.noteConsumed(.terminal)
                    scratch.lastActivityAt = .now
                    if outputError != nil { outputError = nil }
                    switch event {
                    case .ready, .activity:
                        if terminalSource == .disconnected {
                            displayCachedSnapshot()
                            terminalSource = .snapshot
                            renderedOutput = nil
                        }
                    case let .frame(frame):
                        HerdrPerfDiagnostics.checkpoint("terminal.frame")
                        guard working.apply(frame) else { throw APIError.invalidResponse }
                        retryDelay = 0.65
                        switch pending.coalescer.register(now: clock.now) {
                        case .commitNow:
                            pending.flushTask?.cancel()
                            pending.flushTask = nil
                            pending.grid = nil
                            commitTerminal(working, sequence: frame.sequence)
                        case let .defer(deadline):
                            pending.grid = working
                            pending.sequence = frame.sequence
                            if pending.flushTask == nil {
                                pending.flushTask = Task { @MainActor in
                                    try? await clock.sleep(until: deadline)
                                    guard !Task.isCancelled, let grid = pending.grid else { return }
                                    pending.grid = nil
                                    pending.coalescer.markCommitted(now: clock.now)
                                    self.commitTerminal(grid, sequence: pending.sequence)
                                    pending.flushTask = nil
                                }
                            }
                        }
                    }
                }
                throw APIError.streamEnded
            } catch is CancellationError {
                return
            } catch {
                if let grid = pending.grid {
                    pending.flushTask?.cancel()
                    pending.flushTask = nil
                    pending.grid = nil
                    pending.coalescer.markCommitted(now: clock.now)
                    terminalGrid = grid
                    if frameSequence != pending.sequence { frameSequence = pending.sequence }
                }
                scratch.lastActivityAt = nil
                displayCachedSnapshot()
                if terminalSource != .snapshot { terminalSource = .snapshot }
                if renderedOutput != nil { renderedOutput = nil }
                await refreshOutput(forceSnapshot: true)
            }

            do {
                try await Task.sleep(for: .seconds(retryDelay))
            } catch {
                return
            }
            retryDelay = min(retryDelay * 1.7, 5)
        }
    }

    private func pollSnapshots() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: isStreamHealthy ? .seconds(5) : .milliseconds(850))
            } catch {
                return
            }
            await refreshOutput(forceSnapshot: false)
        }
    }

    private func refreshOutput(forceSnapshot: Bool) async {
        snapshotRequestSequence &+= 1
        let requestSequence = snapshotRequestSequence
        let requestedPaneID = currentPane.id
        do {
            let frameAtRequestStart = frameSequence
            let response = try await model.fetchOutput(for: currentPane)
            try Task.checkCancellation()
            guard requestSequence == snapshotRequestSequence,
                  response.paneID.isEmpty || response.paneID == requestedPaneID,
                  response.revision == 0 || scratch.lastSnapshotRevision == 0 || response.revision >= scratch.lastSnapshotRevision
            else { return }

            let streamAdvancedDuringRequest = frameSequence != frameAtRequestStart
            let snapshotText = response.text.isEmpty ? "No terminal output yet." : response.text
            let snapshotChanged = snapshotText != scratch.lastSnapshotText
            scratch.lastSnapshotText = snapshotText
            scratch.lastSnapshotRevision = response.revision
            let textChanged = snapshotText != output
            let framesSincePreviousSnapshot = frameAtRequestStart != snapshotFrameSequence
                || streamAdvancedDuringRequest
            let shouldDisplaySnapshot = TerminalRefreshPolicy.shouldDisplaySnapshot(
                force: forceSnapshot,
                streamAdvancedDuringRequest: streamAdvancedDuringRequest,
                snapshotChangedWithoutFrame: snapshotChanged && !framesSincePreviousSnapshot,
                lastStreamActivityAt: scratch.lastActivityAt
            )

            if shouldDisplaySnapshot || terminalSource == .disconnected {
                if terminalSource != .snapshot { terminalSource = .snapshot }
                if renderedOutput != nil { renderedOutput = nil }
            }
            if outputError != nil { outputError = nil }
            if snapshotFrameSequence != frameSequence { snapshotFrameSequence = frameSequence }
            if (shouldDisplaySnapshot || terminalSource != .stream), textChanged { output = snapshotText }
            if snapshotRevision != response.revision { snapshotRevision = response.revision }
        } catch is CancellationError {
            return
        } catch {
            if terminalSource != .stream || TerminalRefreshPolicy.isStreamStale(
                lastStreamActivityAt: scratch.lastActivityAt
            ) {
                if terminalSource != .disconnected {
                    displayCachedSnapshot()
                    terminalSource = .disconnected
                    if renderedOutput != nil { renderedOutput = nil }
                }
                let message = error.localizedDescription
                if outputError != message { outputError = message }
            }
        }
    }

    private func resetTerminal() {
        snapshotRequestSequence &+= 1
        output = "Connecting to terminal…"
        snapshotRevision = 0
        snapshotFrameSequence = 0
        frameSequence = 0
        terminalGrid = TerminalGrid(columns: 100, rows: 32)
        renderedOutput = nil
        terminalSource = .connecting
        scratch.lastActivityAt = nil
        scratch.lastSnapshotText = nil
        scratch.lastSnapshotRevision = 0
        isFollowing = true
        manualRefreshGeneration = 0
        manualRefreshPaneID = nil
        isManuallyRefreshing = false
        outputError = nil
    }

    private func commitTerminal(_ grid: TerminalGrid, sequence: Int) {
        HerdrPerfDiagnostics.checkpoint("terminal.commit")
        terminalGrid = grid
        if frameSequence != sequence { frameSequence = sequence }
        if terminalSource != .stream { terminalSource = .stream }
        renderedOutput = grid.attributedText(scale: fontScale)
    }

    private func displayCachedSnapshot() {
        guard let text = scratch.lastSnapshotText, text != output else { return }
        output = text
        if snapshotRevision != scratch.lastSnapshotRevision {
            snapshotRevision = scratch.lastSnapshotRevision
        }
    }

    private func manualRefresh() {
        guard !isManuallyRefreshing else { return }
        manualRefreshPaneID = currentPane.id
        manualRefreshGeneration &+= 1
    }
}
