import SwiftUI

struct PiThinkingDisclosureView: View {
    let block: PiThinkingBlock
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var hapticPulse = HerdrHapticPulse()

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            PiMarkdownText(visibleText, font: .callout)
                .foregroundStyle(HerdrTheme.mist)
                .padding(.top, 10)
        } label: {
            HStack(spacing: 9) {
                if block.isStreaming {
                    ProgressView()
                        .controlSize(.small)
                        .tint(HerdrTheme.mauve)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "brain.head.profile")
                        .foregroundStyle(HerdrTheme.mauve)
                        .accessibilityHidden(true)
                }

                Text(block.isStreaming ? "Thinking" : "Thought process")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HerdrTheme.mist)

                Spacer(minLength: 8)

                if block.isStreaming, let startedAt = block.startedAt {
                    Text(startedAt, style: .relative)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(HerdrTheme.muted)
                }
            }
        }
        .tint(HerdrTheme.mauve)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(HerdrTheme.elevated.opacity(0.46), in: RoundedRectangle(cornerRadius: 11))
        .animation(reduceMotion ? nil : .snappy(duration: 0.22, extraBounce: 0), value: isExpanded)
        .onChange(of: isExpanded) { _, expanded in
            hapticPulse.fire(expanded ? .controlsExpanded : .controlsCollapsed)
        }
        .herdrHaptic(trigger: hapticPulse)
        .contentShape(Rectangle())
        .frame(minHeight: 44)
        .accessibilityIdentifier("pi-thinking-\(block.id)")
    }

    private var visibleText: String {
        if block.isRedacted { return "Reasoning details are unavailable for this response." }
        if block.text.isEmpty { return block.isStreaming ? "Pi is working through the request…" : "No reasoning text was provided." }
        return block.text
    }
}
