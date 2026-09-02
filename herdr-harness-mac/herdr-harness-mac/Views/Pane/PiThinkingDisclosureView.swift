import SwiftUI

struct PiThinkingDisclosureView: View {
    let block: PiThinkingBlock
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.herdrFontScale) private var fontScale
    @State private var isExpanded = false
    @State private var hapticPulse = HerdrHapticPulse()

    var body: some View {
        PiDisclosureCard(isExpanded: $isExpanded) {
            markdownContent()
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
                            .foregroundStyle(HerdrTheme.mauve)
                            .transition(PiChatMotion.stateTransition(reduceMotion: reduceMotion))
                    }
                }
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)

                Text(block.isStreaming ? "Thinking" : "Thought process")
                    .herdrFont(.caption, weight: .semibold)
                    .foregroundStyle(HerdrTheme.mist)
                    .contentTransition(.opacity)

                Spacer(minLength: 8)

                if block.isStreaming, let startedAt = block.startedAt {
                    Text(startedAt, style: .relative)
                        .herdrFont(.caption, monospacedDigit: true)
                        .foregroundStyle(HerdrTheme.muted)
                        .transition(.opacity)
                }
            }
        }
        .tint(HerdrTheme.mauve)
        // This padding sits outside the header button, so that band is deliberately not clickable.
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(HerdrTheme.elevated.opacity(0.46), in: RoundedRectangle(cornerRadius: 11))
        .animation(PiChatMotion.disclosureAnimation(reduceMotion: reduceMotion), value: isExpanded)
        .animation(PiChatMotion.stateAnimation(reduceMotion: reduceMotion), value: block.isStreaming)
        .onChange(of: isExpanded) { _, expanded in
            hapticPulse.fire(expanded ? .controlsExpanded : .controlsCollapsed)
        }
        .onChange(of: block.isStreaming) { wasStreaming, isStreaming in
            guard wasStreaming, !isStreaming else { return }
            PiMarkdownInlineCache.shared.evictStreaming(id: block.id)
        }
        .herdrHaptic(trigger: hapticPulse)
        .frame(minHeight: 44)
        .accessibilityIdentifier("pi-thinking-\(block.id)")
        .opacity(HerdrProse.subOutputOpacity)
    }

    private func markdownContent() -> some View {
        let text = visibleText
        let isLiveBlockText = block.isStreaming && !block.isRedacted && !block.text.isEmpty
        if isLiveBlockText {
            PiMarkdownInlineCache.shared.markStreamingEntry(id: block.id, length: text.utf8.count)
        }
        return PiMarkdownText(
            text,
            font: HerdrTheme.scaled(.callout, scale: fontScale),
            id: isLiveBlockText ? block.id : nil,
            cacheKeyLength: isLiveBlockText ? text.utf8.count : nil
        )
        .foregroundStyle(HerdrTheme.mist)
        .padding(.top, 10)
    }

    private var visibleText: String {
        if block.isRedacted { return "Reasoning details are unavailable for this response." }
        if block.text.isEmpty { return block.isStreaming ? "Pi is working through the request…" : "No reasoning text was provided." }
        return block.text
    }
}
