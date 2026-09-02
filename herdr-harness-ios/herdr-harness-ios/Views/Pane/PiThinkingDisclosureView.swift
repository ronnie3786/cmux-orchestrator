import SwiftUI

struct PiThinkingDisclosureView: View {
    let block: PiThinkingBlock
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var hapticPulse = HerdrHapticPulse()

    var body: some View {
        PiDisclosureCard(isExpanded: $isExpanded, chevronColor: HerdrTheme.mauve) {
            PiMarkdownText(visibleText, font: .callout)
                .foregroundStyle(HerdrProse.dimmed(HerdrTheme.mist))
                .padding(.top, 10)
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    if block.isStreaming {
                        ProgressView()
                            .controlSize(.small)
                            .tint(HerdrTheme.mauve)
                            .transition(PiChatMotion.stateTransition(reduceMotion: reduceMotion))
                    } else {
                        Image(systemName: "brain.head.profile")
                            .foregroundStyle(HerdrProse.dimmed(HerdrTheme.mauve))
                            .transition(PiChatMotion.stateTransition(reduceMotion: reduceMotion))
                    }
                }
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)

                Text(block.isStreaming ? "Thinking" : "Thought process")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HerdrProse.dimmed(HerdrTheme.mist))
                    .contentTransition(.opacity)

                Spacer(minLength: 8)

                if block.isStreaming, let startedAt = block.startedAt {
                    Text(startedAt, style: .relative)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(HerdrProse.dimmed(HerdrTheme.muted))
                        .transition(.opacity)
                }
            }
        }
        .background(HerdrTheme.elevated.opacity(0.46), in: RoundedRectangle(cornerRadius: 11))
        .animation(PiChatMotion.disclosureAnimation(reduceMotion: reduceMotion), value: isExpanded)
        .animation(PiChatMotion.stateAnimation(reduceMotion: reduceMotion), value: block.isStreaming)
        .onChange(of: isExpanded) { _, expanded in
            hapticPulse.fire(expanded ? .controlsExpanded : .controlsCollapsed)
        }
        .herdrHaptic(trigger: hapticPulse)
        .frame(minHeight: 44)
        .accessibilityIdentifier("pi-thinking-\(block.id)")
    }

    private var visibleText: String {
        if block.isRedacted { return "Reasoning details are unavailable for this response." }
        if block.text.isEmpty { return block.isStreaming ? "Pi is working through the request…" : "No reasoning text was provided." }
        return block.text
    }
}
