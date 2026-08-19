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
    @State private var hasRevealedContent = false

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
                    hasRevealedContent ? PiChatMotion.structuralAnimation(reduceMotion: reduceMotion) : nil,
                    value: structure
                )
            }
            .scrollPosition($scrollPosition)
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture().onEnded { _ in
                    onKeyboardDismissRequested()
                }
            )
            .onAppear {
                lastAutoScrollStructure = structure
                hasRevealedContent = structure.identifiers.contains("transcript:content")
            }
            .onChange(of: store.revision) { _, _ in
                let previousStructure = lastAutoScrollStructure
                let structureChanged = previousStructure != structure
                lastAutoScrollStructure = structure

                let hadContent = previousStructure?.identifiers.contains("transcript:content") ?? false
                let hasContentNow = structure.identifiers.contains("transcript:content")

                if hasContentNow, !hadContent {
                    // Initial reveal of a populated transcript: do NOT animate a scrollTo here.
                    // Animating scrollTo(edge: .bottom) here resolves against the LazyVStack's
                    // ESTIMATED content height, which shrinks as real rows lay out and leaves the
                    // viewport stranded past the end of content. `.defaultScrollAnchor(.bottom)`
                    // keeps the viewport pinned to the bottom as content grows, so just let it.
                    hasRevealedContent = true
                    isNearBottom = true
                    Task { @MainActor in
                        // Belt-and-braces re-clamp once layout has settled, but only if the
                        // user hasn't scrolled away in the meantime.
                        guard isNearBottom else { return }
                        scrollPosition.scrollTo(edge: .bottom)
                    }
                    return
                }

                if !hasContentNow {
                    // Store reset back to empty (e.g. reconnect/session switch) — take the
                    // reveal path again on the next population.
                    hasRevealedContent = false
                }

                guard isNearBottom else { return }

                if structureChanged, !reduceMotion {
                    withAnimation(PiChatMotion.structuralAnimation(reduceMotion: reduceMotion)) {
                        scrollPosition.scrollTo(edge: .bottom)
                    }
                } else {
                    // Deliberately no animation while tokens and tool output stream.
                    scrollPosition.scrollTo(edge: .bottom)
                }
            }

            if !isNearBottom {
                Button("Jump to latest", systemImage: "arrow.down") {
                    scrollPosition.scrollTo(edge: .bottom)
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
        .animation(
            PiChatMotion.stateAnimation(reduceMotion: reduceMotion),
            value: isNearBottom
        )
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
}
