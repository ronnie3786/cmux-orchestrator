import SwiftUI

struct PiChatTimelineView: View {
    @Bindable var store: PiConversationStore
    let isConnected: Bool
    let resultArtifacts: [AgentResultArtifact]
    let artifactModel: HerdrAppModel?
    let respond: (PiPendingInteraction, PiInteractionResponseBody) async -> Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var isNearBottom = true
    @State private var lastStructureRevision: Int?
    @State private var trackedHasContent = false
    @State private var revealState = PiChatRevealState()
    @State private var settleDebouncer = PiChatSettleDebouncer()
    @State private var showsEarlierRows = false
    /// Rows mounted right now. Starts small so the first paint of a long
    /// transcript is quick, then grows to `PiTimelineWindow.defaultLimit`
    /// once that first frame is on screen (`.task(id:)` below).
    @State private var mountedLimit = PiTimelineWindow.initialLimit

    init(
        store: PiConversationStore,
        isConnected: Bool,
        resultArtifacts: [AgentResultArtifact] = [],
        artifactModel: HerdrAppModel? = nil,
        respond: @escaping (PiPendingInteraction, PiInteractionResponseBody) async -> Bool
    ) {
        self.store = store
        self.isConnected = isConnected
        self.resultArtifacts = resultArtifacts
        self.artifactModel = artifactModel
        self.respond = respond
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                // An EAGER stack, deliberately. A `LazyVStack` here, under a
                // bottom-anchored scroll view whose rows change height while
                // streaming, produced a layout loop inside a single SwiftUI
                // transaction on the work Mac: the lazy stack materialized rows
                // during size estimation, that dirtied the window's root
                // geometry, the root re-measured the tree, the lazy stack
                // materialized again — for minutes, with the main thread
                // pinned and memory climbing to gigabytes (2026-09-02 freeze
                // samples). Eager rows give the scroll view exact sizes in one
                // pass; unchanged rows stay cached through `.equatable()`, and
                // `PiTimelineWindow` bounds how many rows are mounted.
                //
                // Spacing lives on the rows (`PiTimelineRow.topSpacing`) so the
                // rail can run through it; the stack itself adds none.
                VStack(alignment: .leading, spacing: 0) {
                    transcriptHeader
                        .padding(.bottom, HerdrProse.turnSpacing)
                        .transition(.opacity)

                    if store.hasContent {
                        let window = PiTimelineWindow(
                            rows: PiTimelineRow.rows(for: store.turns),
                            showsEarlierRows: showsEarlierRows,
                            limit: mountedLimit
                        )
                        if window.hiddenCount > 0 {
                            earlierRowsButton(hiddenCount: window.hiddenCount)
                                .transition(.opacity)
                        }
                        // One row per segment, never per turn: a streamed token
                        // invalidates a single row. See `PiTimelineRow`.
                        ForEach(window.rows) { row in
                            PiTimelineRowView(row: row)
                                .equatable()
                                .transition(
                                    row.startsTurn
                                        ? PiChatMotion.turnTransition(reduceMotion: reduceMotion)
                                        : PiChatMotion.itemTransition(reduceMotion: reduceMotion)
                                )
                        }
                    } else if store.connection == .connected {
                        emptyTranscript
                            .transition(.opacity)
                    }

                    ForEach(store.pendingInteractions) { interaction in
                        PiInteractionCardView(interaction: interaction, isConnected: isConnected) { response in
                            await respond(interaction, response)
                        }
                        .padding(.top, HerdrProse.turnSpacing)
                        .transition(PiChatMotion.itemTransition(reduceMotion: reduceMotion))
                    }

                    if let artifactModel, !resultArtifacts.isEmpty {
                        Label("Session attachments", systemImage: "paperclip")
                            .herdrFont(.caption, weight: .semibold)
                            .foregroundStyle(HerdrTheme.mist)
                            .padding(.top, HerdrProse.turnSpacing)
                            .padding(.bottom, 8)
                        ForEach(resultArtifacts) { artifact in
                            PaneResultArtifactView(model: artifactModel, artifact: artifact)
                                .padding(.bottom, 8)
                        }
                    }

                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 24)
                .animation(
                    revealState.phase == .revealed
                        ? PiChatMotion.structuralAnimation(reduceMotion: reduceMotion)
                        : nil,
                    value: store.structureRevision
                )
            }
            .scrollPosition($scrollPosition)
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(
                for: PiChatScrollMetrics.self,
                of: {
                    PiChatScrollMetrics(
                        contentHeight: $0.contentSize.height,
                        containerHeight: $0.containerSize.height,
                        visibleRectMaxY: $0.visibleRect.maxY
                    )
                }
            ) { _, metrics in
                let nearBottom = (metrics.contentHeight - metrics.visibleRectMaxY) < 80
                if nearBottom != isNearBottom {
                    isNearBottom = nearBottom
                }
                settleDebouncer.schedule {
                    apply(revealState.settledHeightDidChange(
                        contentHeight: metrics.contentHeight,
                        containerHeight: metrics.containerHeight
                    ))
                }
            }
            .opacity(revealState.phase == .revealed ? 1 : 0)
            .animation(nil, value: revealState.phase)
            .onAppear {
                lastStructureRevision = store.structureRevision
                revealState.structureDidChange(
                    hadContent: false,
                    hasContent: store.hasContent,
                    structureChanged: true,
                    isNearBottom: true,
                    reduceMotion: reduceMotion
                )
                trackedHasContent = store.hasContent
            }
            .onChange(of: store.turns.first?.id) { _, _ in
                // A different transcript (pane switch, session change): start
                // bounded again instead of eagerly mounting a huge history.
                showsEarlierRows = false
                mountedLimit = PiTimelineWindow.initialLimit
            }
            .task(id: store.turns.first?.id) {
                // Grow the mounted window only after the first frame with the
                // newest rows has had a chance to render; the bottom anchor
                // keeps the view in place while earlier rows are inserted.
                guard mountedLimit < PiTimelineWindow.defaultLimit else { return }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                mountedLimit = PiTimelineWindow.defaultLimit
            }
            .onChange(of: store.revision) { _, _ in
                let structureChanged = lastStructureRevision != store.structureRevision
                lastStructureRevision = store.structureRevision
                let hadContent = trackedHasContent
                let hasContentNow = store.hasContent
                trackedHasContent = hasContentNow

                revealState.structureDidChange(
                    hadContent: hadContent,
                    hasContent: hasContentNow,
                    structureChanged: structureChanged,
                    isNearBottom: isNearBottom,
                    reduceMotion: reduceMotion
                )
            }
            .onChange(of: resultArtifacts.map(\.id)) { _, _ in
                if isNearBottom { scrollPosition.scrollTo(edge: .bottom) }
            }

            Group {
                if !isNearBottom {
                    Button("Jump to latest", systemImage: "arrow.down") {
                        withAnimation(PiChatMotion.structuralAnimation(reduceMotion: reduceMotion)) {
                            scrollPosition.scrollTo(edge: .bottom)
                        }
                    }
                    .buttonStyle(PiChatButtonStyle(tint: HerdrTheme.text, emphasis: .text))
                    .herdrFont(.caption, weight: .semibold)
                    .padding(.horizontal, 12)
                    .frame(minHeight: PiChatChrome.controlHeight)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay { Capsule().stroke(HerdrTheme.accent.opacity(0.25), lineWidth: 1) }
                    .padding(14)
                    .transition(PiChatMotion.jumpToLatestTransition(reduceMotion: reduceMotion))
                    .accessibilityIdentifier("pi-chat-jump-latest")
                }
            }
            .animation(PiChatMotion.stateAnimation(reduceMotion: reduceMotion), value: isNearBottom)
        }
    }

    @ViewBuilder
    private var transcriptHeader: some View {
        if store.isTruncated {
            Label("Older context was omitted by Pi", systemImage: "ellipsis.circle")
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.muted)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityLabel("The beginning of this Pi transcript is not available")
        }
    }

    private func earlierRowsButton(hiddenCount: Int) -> some View {
        Button {
            showsEarlierRows = true
        } label: {
            Label(
                "Show \(hiddenCount) earlier \(hiddenCount == 1 ? "row" : "rows")",
                systemImage: "arrow.up.to.line"
            )
        }
        .buttonStyle(PiChatButtonStyle(tint: HerdrTheme.mist, emphasis: .soft))
        .herdrFont(.caption, weight: .semibold)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, HerdrProse.turnSpacing)
        .accessibilityIdentifier("pi-chat-show-earlier")
    }

    private var emptyTranscript: some View {
        ContentUnavailableView(
            "Start a conversation",
            systemImage: "bubble.left.and.bubble.right",
            description: Text("Messages, thinking, and tool activity will appear here. The terminal remains available from the pane menu.")
        )
        .foregroundStyle(HerdrTheme.text)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }

    @MainActor
    private func apply(_ action: PiChatRevealAction) {
        switch action {
        case .none:
            return
        case .revealAfterScrollingToBottom:
            isNearBottom = true
            scrollPosition.scrollTo(edge: .bottom)
        case let .scrollToBottom(animated):
            guard isNearBottom else { return }
            let shouldAnimate = animated && store.phase != .working
            if shouldAnimate {
                withAnimation(PiChatMotion.structuralAnimation(reduceMotion: reduceMotion)) {
                    scrollPosition.scrollTo(edge: .bottom)
                }
            } else {
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
    }
}

@MainActor
private final class PiChatSettleDebouncer {
    private var deadline: ContinuousClock.Instant?
    private var pendingAction: (() -> Void)?
    private var task: Task<Void, Never>?

    func schedule(delay: Duration = .milliseconds(60), _ action: @escaping () -> Void) {
        deadline = ContinuousClock.now.advanced(by: delay)
        pendingAction = action
        guard task == nil else { return }

        task = Task { @MainActor [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                guard let deadline else { return }
                do {
                    try await ContinuousClock().sleep(until: deadline)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard self.deadline == deadline else { continue }

                let action = self.pendingAction
                self.task = nil
                self.deadline = nil
                self.pendingAction = nil
                action?()
                return
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        deadline = nil
        pendingAction = nil
    }
}
