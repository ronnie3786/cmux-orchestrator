import SwiftUI

struct PiChatTimelineView: View {
    @Bindable var store: PiConversationStore
    let isConnected: Bool
    let respond: (PiPendingInteraction, PiInteractionResponseBody) async -> Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var isNearBottom = true

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    transcriptHeader

                    if store.hasContent {
                        ForEach(store.turns) { turn in
                            PiConversationTurnView(turn: turn)
                                .transition(turnTransition)
                        }
                    } else if store.connection == .connected {
                        emptyTranscript
                    }

                    ForEach(store.pendingInteractions) { interaction in
                        PiInteractionCardView(interaction: interaction, isConnected: isConnected) { response in
                            await respond(interaction, response)
                        }
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
            }
            .scrollPosition($scrollPosition)
            .defaultScrollAnchor(.bottom)
            .onChange(of: store.turns.count) { oldCount, newCount in
                guard newCount > oldCount, isNearBottom else { return }
                scrollPosition.scrollTo(edge: .bottom)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isNearBottom)
            .onChange(of: store.revision) { _, _ in
                guard isNearBottom else { return }
                // Deliberately no animation while tokens and tool output stream.
                scrollPosition.scrollTo(edge: .bottom)
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
                .transition(jumpTransition)
                .accessibilityIdentifier("pi-chat-jump-latest")
            }
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

    private var turnTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .opacity.combined(with: .offset(y: 6)),
                removal: .opacity
            )
    }

    private var jumpTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }
}
