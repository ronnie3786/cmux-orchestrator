import SwiftUI

struct PiChatTimelineView: View {
    @Bindable var store: PiConversationStore
    let isConnected: Bool
    let respond: (PiPendingInteraction, PiInteractionResponseBody) async -> Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var isNearBottom = true
    @State private var lastAutoScrollStructure: PiChatTimelineStructure?
    @State private var revealState = PiChatRevealState()
    @State private var settleGeneration = 0

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
        let structure = PiChatTimelineStructure(
            turns: store.turns,
            pendingInteractions: store.pendingInteractions,
            hasContent: store.hasContent,
            isTruncated: store.isTruncated
        )

        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    transcriptHeader
                        .transition(.opacity)

                    if store.hasContent {
                        ForEach(store.turns) { turn in
                            PiConversationTurnView(turn: turn)
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

                    Color.clear
                        .frame(height: 1)
                        .id("pi-chat-bottom")
                        .onScrollVisibilityChange(threshold: 0.1) { isVisible in
                            isNearBottom = isVisible
                        }
                        .accessibilityHidden(true)
                }
                .scrollTargetLayout()
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
                        containerHeight: $0.containerSize.height
                    )
                }
            ) { _, metrics in
                settleGeneration &+= 1
                let generation = settleGeneration
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    guard generation == settleGeneration else { return }
                    apply(revealState.settledHeightDidChange(
                        contentHeight: metrics.contentHeight,
                        containerHeight: metrics.containerHeight
                    ))
                }
            }
            .opacity(revealState.phase == .revealed ? 1 : 0)
            .animation(nil, value: revealState.phase)
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

            if !isNearBottom {
                Button("Jump to latest", systemImage: "arrow.down") {
                    scrollPosition.scrollTo(edge: .bottom)
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
        .animation(
            PiChatMotion.stateAnimation(reduceMotion: reduceMotion),
            value: isNearBottom
        )
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
            if animated {
                withAnimation(PiChatMotion.structuralAnimation(reduceMotion: reduceMotion)) {
                    scrollPosition.scrollTo(edge: .bottom)
                }
            } else {
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
    }
}
