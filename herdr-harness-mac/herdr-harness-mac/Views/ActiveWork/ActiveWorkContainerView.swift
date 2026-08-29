import Foundation
import SwiftUI

struct ActiveWorkContainerView: View {
    @Bindable var store: ActiveWorkStore
    let isControlEnabled: Bool
    let refresh: () async -> Void
    let createItem: (String, String, String) async throws -> Void
    let setupJira: (ActiveWorkJiraCandidate) async throws -> Void
    let transition: (ActiveWorkItem, ActiveWorkPipelineStage) async throws -> Void
    let setLifecycle: (ActiveWorkItem, String) async throws -> Void
    let openSession: (ActiveWorkPiSession) -> Void
    let openURL: (URL) -> Void
    let transcribeVoice: (URL) async throws -> VoiceTranscription
    let askBoard: (String?) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingCreateWork = false
    @State private var isShowingVoiceRecorder = false
    @State private var pendingVoicePrompt: String?

    init(
        store: ActiveWorkStore,
        isControlEnabled: Bool,
        refresh: @escaping () async -> Void,
        createItem: @escaping (String, String, String) async throws -> Void,
        setupJira: @escaping (ActiveWorkJiraCandidate) async throws -> Void,
        transition: @escaping (ActiveWorkItem, ActiveWorkPipelineStage) async throws -> Void,
        setLifecycle: @escaping (ActiveWorkItem, String) async throws -> Void,
        openSession: @escaping (ActiveWorkPiSession) -> Void,
        openURL: @escaping (URL) -> Void,
        transcribeVoice: @escaping (URL) async throws -> VoiceTranscription,
        askBoard: @escaping (String?) -> Void
    ) {
        self.store = store
        self.isControlEnabled = isControlEnabled
        self.refresh = refresh
        self.createItem = createItem
        self.setupJira = setupJira
        self.transition = transition
        self.setLifecycle = setLifecycle
        self.openSession = openSession
        self.openURL = openURL
        self.transcribeVoice = transcribeVoice
        self.askBoard = askBoard
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            HerdrBackground()

            VStack(spacing: 0) {
                header

                Rectangle()
                    .fill(HerdrTheme.surface.opacity(0.72))
                    .frame(height: 1)

                if let errorMessage {
                    ActiveWorkErrorBanner(message: errorMessage)
                        .padding(.horizontal, HerdrTheme.pagePadding)
                        .padding(.top, 12)
                }

                if let jiraSourceError {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Jira candidates are temporarily unavailable")
                                .herdrFont(.subheadline, weight: .bold)
                            Text("Tracked board records remain available. Jira candidates and ticket statuses may be stale. \(jiraSourceError)")
                                .herdrFont(.caption, monospaced: true)
                                .lineLimit(2)
                        }
                    } icon: {
                        Image(systemName: "checkmark.square.trianglebadge.exclamationmark")
                    }
                    .foregroundStyle(HerdrTheme.working)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(HerdrTheme.working.opacity(0.09))
                    .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
                    .padding(.horizontal, HerdrTheme.pagePadding)
                    .padding(.top, 12)
                    .accessibilityIdentifier("active-work-jira-source-warning")
                }

                content
            }

            if store.hasLoaded, !store.isEmpty {
                voiceButton
                    .padding(20)
            }

        }
        .navigationTitle("Active Work")
        // Keep the container addressable without replacing the board, focus
        // route, card, and action identifiers published by its descendants.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("active-work-container")
        .task {
            guard !store.hasLoaded else { return }
            await refresh()
        }
        .sheet(isPresented: $isShowingCreateWork) {
            ActiveWorkCreateSheet(create: createItem)
        }
        .sheet(isPresented: $isShowingVoiceRecorder, onDismiss: presentPendingVoicePrompt) {
            HerdrVoiceNoteRecorderSheet(
                save: { _ in },
                transcribe: transcribeVoice,
                insertTranscript: { result in
                    let prompt = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    pendingVoicePrompt = prompt.isEmpty
                        ? "What needs my attention on this board, and what should move next?"
                        : prompt
                    isShowingVoiceRecorder = false
                },
                cancel: { isShowingVoiceRecorder = false },
                allowsRawSave: false
            )
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            ZStack {
                modePicker

                HStack(spacing: 8) {
                    Spacer()
                    topVoiceButton
                    moreMenu
                }
            }
            .padding(.horizontal, HerdrTheme.pagePadding)
            .padding(.vertical, 9)

            Rectangle()
                .fill(HerdrTheme.surface.opacity(0.42))
                .frame(height: 1)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    headerTitle
                        .frame(maxWidth: .infinity, alignment: .leading)
                    headerActions
                        .fixedSize()
                        .layoutPriority(1)
                }

                VStack(alignment: .leading, spacing: 12) {
                    headerTitle
                    headerActions
                }
            }
            .frame(maxWidth: 1120, alignment: .leading)
            .padding(.horizontal, HerdrTheme.pagePadding)
            .padding(.top, 20)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
        }
        .background(HerdrTheme.ink.opacity(0.94))
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(store.viewMode == .board ? "Active work" : "Focus route")
                .herdrFont(size: 30, weight: .bold, relativeTo: .largeTitle)
                .fontDesign(.rounded)
                .foregroundStyle(HerdrTheme.text)
            Text(
                store.viewMode == .board
                    ? "Each item carries its agents through the full Buzz pipeline."
                    : "One item in depth, with its stage history and complete traveling cast."
            )
            .herdrFont(.subheadline)
            .foregroundStyle(HerdrTheme.mist)
        }
    }

    private var modePicker: some View {
        Picker("View", selection: modeBinding) {
            ForEach(ActiveWorkViewMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 272)
        .accessibilityIdentifier("active-work-mode-picker")
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            if store.viewMode == .board {
                refreshButton
            } else {
                Button("Open handoff") {
                    openSelectedHandoff()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canOpenSelectedHandoff)
                .help(canOpenSelectedHandoff ? "Open the selected work's live handoff" : "No live handoff is attached")
                .accessibilityIdentifier("active-work-open-handoff")
            }

            Button("Ask board", systemImage: "sparkles") {
                askBoard(nil)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(HerdrTheme.accent)
            .disabled(!isControlEnabled)
            .help(isControlEnabled ? "Open an agent grounded in this board" : "Control access is required to launch an agent")
            .accessibilityIdentifier("active-work-ask-board")
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await refresh() }
        } label: {
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .frame(minWidth: 58)
            } else {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(store.isRefreshing)
        .help("Refresh Active Work")
        .accessibilityIdentifier("active-work-refresh")
    }

    private var topVoiceButton: some View {
        Button {
            isShowingVoiceRecorder = true
        } label: {
            Image(systemName: "mic.fill")
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(HerdrTheme.accent)
        .disabled(!isControlEnabled)
        .help(isControlEnabled ? "Ask this board by voice" : "Control access is required for board voice prompts")
        .accessibilityLabel("Ask this board by voice")
        .accessibilityIdentifier("active-work-voice-prompt-header")
    }

    private var voiceButton: some View {
        Button {
            isShowingVoiceRecorder = true
        } label: {
            Image(systemName: "mic.fill")
                .herdrFont(.title3, weight: .bold)
                .frame(width: 46, height: 46)
        }
        .buttonStyle(.plain)
        .foregroundStyle(HerdrTheme.ink)
        .background(HerdrTheme.accent, in: .rect(cornerRadius: HerdrTheme.compactRadius))
        .shadow(color: .black.opacity(0.32), radius: 14, y: 8)
        .disabled(!isControlEnabled)
        .help(isControlEnabled ? "Ask this board by voice" : "Control access is required for board voice prompts")
        .accessibilityLabel("Ask this board by voice")
        .accessibilityIdentifier("active-work-voice-prompt")
    }

    private var moreMenu: some View {
        Menu {
            Button("New work", systemImage: "plus") {
                isShowingCreateWork = true
            }
            .disabled(!isControlEnabled)
            .accessibilityIdentifier("active-work-new-item")

            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await refresh() }
            }
            .disabled(store.isRefreshing)

        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("More Active Work actions")
        .accessibilityLabel("More Active Work actions")
    }

    private var canOpenSelectedHandoff: Bool {
        guard let item = store.selectedItem else { return false }
        return item.piSessions.contains(where: { $0.paneID?.isEmpty == false })
            || item.threads.contains(where: { $0.browserURL != nil })
    }

    private func openSelectedHandoff() {
        guard let item = store.selectedItem else { return }
        if let session = item.piSessions.first(where: { $0.paneID?.isEmpty == false }) {
            openSession(session)
        } else if let url = item.threads.compactMap(\.browserURL).first {
            openURL(url)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !store.hasLoaded && store.isEmpty {
            VStack(spacing: 12) {
                ProgressView().tint(HerdrTheme.accent)
                Text("Loading your Active Work board…")
                    .herdrFont(.body)
                    .foregroundStyle(HerdrTheme.mist)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("active-work-loading")
        } else if store.isEmpty, store.hasError {
            ContentUnavailableView {
                Label("Active Work unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Herdr could not load the durable board. Check the connection and try again.")
            } actions: {
                Button("Retry", systemImage: "arrow.clockwise") {
                    Task { await refresh() }
                }
                .disabled(store.isRefreshing)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("active-work-unavailable")
        } else if store.isEmpty {
            ContentUnavailableView {
                Label("No active work yet", systemImage: "rectangle.3.group")
            } description: {
                Text(
                    store.response.jiraCandidatesStatus.ok
                        ? "Assigned Jira work will appear here for one-click setup, then travel through the shared pipeline."
                        : "No tracked board records are available. Jira candidates and ticket statuses could not refresh."
                )
            } actions: {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await refresh() }
                }
                .disabled(store.isRefreshing)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("active-work-empty")
        } else {
            switch store.viewMode {
            case .board:
                ActiveWorkBoardView(
                    store: store,
                    isControlEnabled: isControlEnabled,
                    setupJira: setupJira,
                    openURL: openURL
                )
                    .transition(reduceMotion ? .identity : .opacity)
            case .focusRoute:
                ActiveWorkFocusRouteView(
                    store: store,
                    isControlEnabled: isControlEnabled,
                    openSession: openSession,
                    openURL: openURL,
                    transition: transition,
                    setLifecycle: setLifecycle
                )
                .transition(reduceMotion ? .identity : .opacity)
            }
        }
    }

    private var modeBinding: Binding<ActiveWorkViewMode> {
        Binding(
            get: { store.viewMode },
            set: { mode in
                if reduceMotion {
                    store.show(mode)
                } else {
                    withAnimation(.snappy(duration: 0.2)) {
                        store.show(mode)
                    }
                }
            }
        )
    }

    private var errorMessage: String? {
        if let transportError = store.transportError { return transportError }
        if store.hasLoaded, !store.response.ok { return "The server returned an incomplete Active Work response." }
        return nil
    }

    private var jiraSourceError: String? {
        guard store.hasLoaded, !store.response.jiraCandidatesStatus.ok else { return nil }
        return store.response.jiraCandidatesStatus.error ?? "The Jira source did not respond."
    }

    private func presentPendingVoicePrompt() {
        guard let prompt = pendingVoicePrompt else { return }
        pendingVoicePrompt = nil
        askBoard(prompt)
    }
}
