import SwiftUI

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
    @FocusState private var isTerminalFocused: Bool
    @State private var keyboardRouter = TerminalKeyboardRouter()
    @State private var output = "Connecting to terminal…"
    @State private var snapshotRevision = 0
    @State private var snapshotFrameSequence = 0
    @State private var snapshotRequestSequence = 0
    @State private var frameSequence = 0
    @State private var terminalGrid = TerminalGrid(columns: 100, rows: 32)
    @State private var terminalSource: TerminalSource = .connecting
    @State private var lastStreamActivityAt: Date?
    @State private var isFollowing = true
    @State private var manualRefreshGeneration = 0
    @State private var manualRefreshPaneID: String?
    @State private var isManuallyRefreshing = false
    @State private var outputError: String?
    @State private var selectedMode: PaneDetailMode = .terminal
    @State private var piConversationStore = PiConversationStore()
    @State private var didAutoSelectChat = false
    @State private var composerDraft = ""
    @State private var composerAttachments: [TerminalAttachment] = []
    @State private var composerFocusRequest = 0

    var body: some View {
        ZStack {
            HerdrBackground()

            VStack(spacing: 0) {
                PaneSessionHeader(model: model, pane: currentPane)
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
            guard manualRefreshGeneration > 0,
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
                    .font(.caption.bold())
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
                    pane: currentPane,
                    workspace: workspace,
                    draft: $composerDraft,
                    attachments: $composerAttachments,
                    focusRequest: composerFocusRequest
                )
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
                attributedOutput: terminalSource == .stream ? terminalGrid.attributedText : nil,
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
        "\(pane.id):\(model.connectionGeneration)"
    }

    private var manualRefreshTaskID: String {
        "\(followTaskID):refresh:\(manualRefreshGeneration)"
    }

    private var piChatTaskID: String {
        "\(pane.id):pi-chat:\(model.connectionGeneration):\(selectedMode.rawValue)"
    }

    private func followOutput() async {
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
        var retryDelay = 0.65
        while !Task.isCancelled {
            do {
                guard let events = await model.terminalEvents(for: currentPane) else {
                    terminalSource = .snapshot
                    try await Task.sleep(for: .seconds(retryDelay))
                    continue
                }

                for try await event in events {
                    try Task.checkCancellation()
                    lastStreamActivityAt = .now
                    outputError = nil
                    switch event {
                    case .ready, .activity:
                        if terminalSource == .disconnected {
                            terminalSource = .snapshot
                        }
                    case let .frame(frame):
                        var updatedGrid = terminalGrid
                        guard updatedGrid.apply(frame) else { throw APIError.invalidResponse }
                        terminalGrid = updatedGrid
                        frameSequence = frame.sequence
                        terminalSource = .stream
                        retryDelay = 0.65
                    }
                }
                throw APIError.streamEnded
            } catch is CancellationError {
                return
            } catch {
                lastStreamActivityAt = nil
                terminalSource = .snapshot
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
                try await Task.sleep(for: .milliseconds(850))
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
                  response.revision == 0 || snapshotRevision == 0 || response.revision >= snapshotRevision
            else { return }

            let streamAdvancedDuringRequest = frameSequence != frameAtRequestStart
            let snapshotText = response.text.isEmpty ? "No terminal output yet." : response.text
            let textChanged = snapshotText != output
            let framesSincePreviousSnapshot = frameAtRequestStart != snapshotFrameSequence
                || streamAdvancedDuringRequest
            let shouldDisplaySnapshot = TerminalRefreshPolicy.shouldDisplaySnapshot(
                force: forceSnapshot,
                streamAdvancedDuringRequest: streamAdvancedDuringRequest,
                snapshotChangedWithoutFrame: textChanged && !framesSincePreviousSnapshot,
                lastStreamActivityAt: lastStreamActivityAt
            )

            if shouldDisplaySnapshot || terminalSource == .disconnected {
                terminalSource = .snapshot
            }
            outputError = nil
            snapshotFrameSequence = frameSequence
            if textChanged { output = snapshotText }
            if snapshotRevision != response.revision { snapshotRevision = response.revision }
        } catch is CancellationError {
            return
        } catch {
            if terminalSource != .stream || TerminalRefreshPolicy.isStreamStale(
                lastStreamActivityAt: lastStreamActivityAt
            ) {
                terminalSource = .disconnected
                outputError = error.localizedDescription
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
        terminalSource = .connecting
        lastStreamActivityAt = nil
        isFollowing = true
        manualRefreshGeneration = 0
        manualRefreshPaneID = nil
        isManuallyRefreshing = false
        outputError = nil
    }

    private func manualRefresh() {
        guard !isManuallyRefreshing else { return }
        manualRefreshPaneID = currentPane.id
        manualRefreshGeneration &+= 1
    }
}
