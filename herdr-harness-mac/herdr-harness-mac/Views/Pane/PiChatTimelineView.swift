import SwiftUI

struct PiChatTimelineView: View {
    @Bindable var store: PiConversationStore
    let isConnected: Bool
    let respond: (PiPendingInteraction, PiInteractionResponseBody) async -> Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var isNearBottom = true
    @State private var lastStructureRevision: Int?
    @State private var trackedHasContent = false
    @State private var revealState = PiChatRevealState()
    @State private var settleDebouncer = PiChatSettleDebouncer()

    init(
        store: PiConversationStore,
        isConnected: Bool,
        respond: @escaping (PiPendingInteraction, PiInteractionResponseBody) async -> Bool
    ) {
        self.store = store
        self.isConnected = isConnected
        self.respond = respond
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: HerdrProse.turnSpacing) {
                    transcriptHeader
                        .transition(.opacity)

                    if store.hasContent {
                        ForEach(store.turns) { turn in
                            PiConversationTurnRow(turn: turn)
                                .equatable()
                                .transition(PiChatMotion.turnTransition(reduceMotion: reduceMotion))
                        }
                    } else if store.connection == .connected {
                        emptyTranscript
                            .transition(.opacity)
                    }

                    ForEach(store.pendingInteractions) { interaction in
                        PiInteractionCardView(interaction: interaction, isConnected: isConnected) { response in
                            await respond(interaction, response)
                        }
                        .transition(PiChatMotion.itemTransition(reduceMotion: reduceMotion))
                    }

                }
                .scrollTargetLayout()
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

private struct PiConversationTurnRow: View, Equatable {
    let turn: PiConversationTurn

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.turn.id == rhs.turn.id
            && lhs.turn.itemsRevision == rhs.turn.itemsRevision
            && lhs.turn.isActive == rhs.turn.isActive
            && lhs.turn.items.last?.diffingTextLength == rhs.turn.items.last?.diffingTextLength
    }

    var body: some View {
        PiConversationTurnView(turn: turn)
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
