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
        ZStack {
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
        }
        .navigationTitle("Active Work")
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
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 14) {
                headerTitle
                Spacer(minLength: 12)
                modePicker
                headerActions
            }

            VStack(alignment: .leading, spacing: 12) {
                headerTitle
                HStack(spacing: 12) {
                    modePicker
                    Spacer(minLength: 4)
                    headerActions
                }
            }
        }
        .padding(.horizontal, HerdrTheme.pagePadding)
        .padding(.vertical, 14)
        .background(HerdrTheme.graphite.opacity(0.82))
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Active Work", systemImage: "rectangle.3.group")
                .herdrFont(.title, weight: .bold)
                .fontDesign(.rounded)
                .foregroundStyle(HerdrTheme.text)
            HStack(spacing: 7) {
                Text(store.pipeline.title)
                if store.pipeline.version > 0 {
                    Text("·")
                    Text("v\(store.pipeline.version)")
                }
                if let lastUpdated = store.lastUpdated {
                    Text("·")
                    Text("updated \(HerdrTimestamp.compactAge(since: lastUpdated))")
                }
            }
            .herdrFont(.caption, monospaced: true)
            .foregroundStyle(HerdrTheme.muted)
        }
    }

    private var modePicker: some View {
        Picker("View", selection: modeBinding) {
            ForEach(ActiveWorkViewMode.allCases) { mode in
                Label(mode.title, systemImage: mode.symbol).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 248)
        .accessibilityIdentifier("active-work-mode-picker")
    }

    private var headerActions: some View {
        HStack(spacing: 12) {
            Button("New work", systemImage: "plus") {
                isShowingCreateWork = true
            }
            .buttonStyle(.bordered)
            .tint(HerdrTheme.accent)
            .disabled(!isControlEnabled)
            .help(isControlEnabled ? "Create a feature, task, or idea" : "Control access is required to create work")
            .accessibilityIdentifier("active-work-new-item")

            Button("Ask board", systemImage: "sparkles") {
                askBoard(nil)
            }
            .buttonStyle(.bordered)
            .tint(HerdrTheme.mauve)
            .labelStyle(.iconOnly)
            .disabled(!isControlEnabled)
            .help(isControlEnabled ? "Open an agent grounded in this board" : "Control access is required to launch an agent")
            .accessibilityIdentifier("active-work-ask-board")

            Button {
                isShowingVoiceRecorder = true
            } label: {
                Image(systemName: "mic.fill")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderedProminent)
            .tint(HerdrTheme.accent)
            .disabled(!isControlEnabled)
            .help(isControlEnabled ? "Record a voice question about this board" : "Control access is required for board voice prompts")
            .accessibilityLabel("Ask this board by voice")
            .accessibilityIdentifier("active-work-voice-prompt")

            Button {
                Task { await refresh() }
            } label: {
                Group {
                    if store.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 30, height: 30)
            }
            .buttonStyle(.bordered)
            .tint(HerdrTheme.mist)
            .disabled(store.isRefreshing)
            .help("Refresh Active Work")
            .accessibilityLabel("Refresh Active Work")
            .accessibilityIdentifier("active-work-refresh")
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
