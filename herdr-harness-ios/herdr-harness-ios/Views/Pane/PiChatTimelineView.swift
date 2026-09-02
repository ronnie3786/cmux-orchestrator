import SwiftUI

struct PiChatTimelineView: View {
    @Bindable var store: PiConversationStore
    let isConnected: Bool
    let onKeyboardDismissRequested: () -> Void
    let respond: (PiPendingInteraction, PiInteractionResponseBody) async -> Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var isNearBottom = true
    @State private var lastAutoScrollStructure: PiChatTimelineStructure?
    @State private var revealState = PiChatRevealState()
    @State private var settleDebouncer = PiChatSettleDebouncer()
    @State private var showsEarlierRows = false

    init(
        store: PiConversationStore,
        isConnected: Bool,
        onKeyboardDismissRequested: @escaping () -> Void = {},
        respond: @escaping (PiPendingInteraction, PiInteractionResponseBody) async -> Bool
    ) {
        self.store = store
        self.isConnected = isConnected
        self.onKeyboardDismissRequested = onKeyboardDismissRequested
        self.respond = respond
    }

    var body: some View {
        let structure = PiChatTimelineStructure(
            turns: store.turns,
            pendingInteractions: store.pendingInteractions,
            hasContent: store.hasContent,
            isTruncated: store.isTruncated
        )

        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                // Deliberately still LAZY, unlike the Mac twin. The Mac had to
                // go eager because a `LazyVStack` under a bottom-anchored
                // scroll view dirtied the *window's* root geometry while
                // estimating row sizes, which re-measured the tree, which
                // materialized rows again — a layout loop inside one SwiftUI
                // transaction (2026-09-02 freeze samples). That is an AppKit
                // window-geometry pathology with no iOS equivalent, and with
                // one row per segment the rows are short and uniform enough
                // that the lazy stack's height estimates get better, not worse.
                // If iOS ever shows the same symptom (a pinned core with no
                // forward progress while streaming), the escape hatch is one
                // word — `VStack` — plus the Mac's `initialLimit` ramp.
                //
                // Spacing lives on the rows (`PiTimelineRow.topSpacing`) so the
                // rail can run through it; the stack itself adds none.
                LazyVStack(alignment: .leading, spacing: 0) {
                    transcriptHeader
                        .padding(.bottom, HerdrProse.turnSpacing)
                        .transition(.opacity)

                    if store.hasContent {
                        let window = PiTimelineWindow(
                            rows: PiTimelineRow.rows(for: store.turns),
                            showsEarlierRows: showsEarlierRows
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
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 24)
                .animation(
                    revealState.phase == .revealed
                        ? PiChatMotion.structuralAnimation(reduceMotion: reduceMotion)
                        : nil,
                    value: structure
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
                // 80pt of tolerance, not "the last pixel is visible": while Pi
                // streams and content grows, a reader sitting just off the
                // bottom must keep autoscroll instead of being handed a
                // flashing jump-to-latest button.
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
            .scrollDismissesKeyboard(.interactively)
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture().onEnded { _ in
                    onKeyboardDismissRequested()
                }
            )
            .onAppear {
                lastAutoScrollStructure = structure
                revealState.structureDidChange(
                    hadContent: false,
                    hasContent: structure.identifiers.contains("transcript:content"),
                    structureChanged: true,
                    isNearBottom: true,
                    reduceMotion: reduceMotion
                )
            }
            .onChange(of: store.turns.first?.id) { _, _ in
                // A different transcript (session change inside the same pane):
                // start bounded again instead of mounting a huge history.
                showsEarlierRows = false
            }
            .onChange(of: store.revision) { _, _ in
                let previousStructure = lastAutoScrollStructure
                let structureChanged = previousStructure != structure
                lastAutoScrollStructure = structure

                let hadContent = previousStructure?.identifiers.contains("transcript:content") ?? false
                let hasContentNow = structure.identifiers.contains("transcript:content")

                revealState.structureDidChange(
                    hadContent: hadContent,
                    hasContent: hasContentNow,
                    structureChanged: structureChanged,
                    isNearBottom: isNearBottom,
                    reduceMotion: reduceMotion
                )
            }

            // The implicit animation is scoped to the button alone. On the
            // ZStack it covered the whole transcript subtree — harmless with 30
            // turn views, not harmless with 160 rows.
            Group {
                if !isNearBottom {
                    Button("Jump to latest", systemImage: "arrow.down") {
                        withAnimation(PiChatMotion.structuralAnimation(reduceMotion: reduceMotion)) {
                            scrollPosition.scrollTo(edge: .bottom)
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HerdrTheme.text)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
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
                .font(.caption)
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
            .font(.caption.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .tint(HerdrTheme.mist)
        .frame(minHeight: 44)
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
            // Never animate the re-anchor while Pi is streaming: the animation
            // is re-triggered on every settled height change, so it fights the
            // next token instead of finishing.
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

/// Collapses a burst of scroll-geometry callbacks into one settled reading.
/// A single long-lived task re-arms its own deadline instead of spawning a
/// task per callback — geometry fires on every streamed token, and one
/// `Task` allocation per token is real main-thread work.
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
