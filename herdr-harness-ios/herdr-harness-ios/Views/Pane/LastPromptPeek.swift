import SwiftUI

struct LastPromptPeekButton: View {
    let message: PiUserMessage?
    @State private var isPresented = false

    var body: some View {
        Button("Last prompt", systemImage: "text.bubble.badge.clock") {
            isPresented = true
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(message == nil ? HerdrTheme.mist.opacity(0.4) : HerdrTheme.accent)
        .disabled(message == nil)
        .accessibilityIdentifier("pane-last-prompt")
        .accessibilityHint("Shows the most recent prompt sent to Pi")
        .sheet(isPresented: $isPresented) {
            if let message {
                LastPromptPeekSheet(message: message)
                    .presentationDetents([.medium])
            }
        }
    }
}

private struct LastPromptPeekSheet: View {
    let message: PiUserMessage
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: HerdrTheme.rowSpacing) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("last prompt")
                        .font(.headline.monospaced().weight(.bold))
                        .foregroundStyle(HerdrTheme.text)
                    timestampCaption
                }

                Spacer(minLength: 12)

                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    copy()
                }
                .font(.caption.monospaced().weight(.medium))
                .foregroundStyle(copied ? HerdrTheme.success : HerdrTheme.accent)
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("pane-last-prompt-copy")
                .accessibilityLabel(copied ? "Prompt copied" : "Copy prompt")
            }

            Rectangle()
                .fill(HerdrTheme.surface)
                .frame(height: 1)

            ScrollView {
                PiMarkdownText(message.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            }
            .scrollIndicators(.visible)
        }
        .padding(HerdrTheme.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(HerdrTheme.ink)
    }

    @ViewBuilder
    private var timestampCaption: some View {
        if let timestamp = message.timestamp {
            Text("what you asked · \(timestamp, style: .relative)")
                .font(.caption.monospaced())
                .foregroundStyle(HerdrTheme.mist)
        } else {
            Text("what you asked")
                .font(.caption.monospaced())
                .foregroundStyle(HerdrTheme.mist)
        }
    }

    private func copy() {
        UIPasteboard.general.string = message.text
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            copied = false
        }
    }
}
