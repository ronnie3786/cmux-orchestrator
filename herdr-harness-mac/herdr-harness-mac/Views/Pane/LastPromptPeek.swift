import AppKit
import SwiftUI

struct LastPromptPeekButton: View {
    let message: PiUserMessage?
    @Environment(\.herdrFontScale) private var fontScale
    @State private var isPresented = false
    @State private var copied = false

    var body: some View {
        Button("Last prompt", systemImage: "text.bubble.badge.clock") {
            isPresented = true
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(message == nil ? HerdrTheme.mist.opacity(0.4) : HerdrTheme.mist)
        .frame(width: 30, height: 28)
        .contentShape(.rect)
        .background(HerdrTheme.graphite)
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(HerdrTheme.surface, lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
        .buttonStyle(.plain)
        .disabled(message == nil)
        .help("See what you last asked")
        .accessibilityIdentifier("pane-last-prompt")
        .accessibilityHint("Shows the most recent prompt sent to Pi")
        .popover(isPresented: $isPresented) {
            if let message {
                popoverContent(message)
            }
        }
    }

    private func popoverContent(_ message: PiUserMessage) -> some View {
        VStack(alignment: .leading, spacing: HerdrTheme.rowSpacing) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("last prompt")
                        .herdrFont(.subheadline, monospaced: true, weight: .bold)
                        .foregroundStyle(HerdrTheme.text)
                    timestampCaption(for: message)
                }

                Spacer(minLength: 12)

                Button {
                    copy(message.text)
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .herdrHitTarget(minWidth: 0)
                }
                .herdrFont(.caption, monospaced: true, weight: .medium)
                .foregroundStyle(copied ? HerdrTheme.success : HerdrTheme.accent)
                .buttonStyle(.plain)
                .accessibilityIdentifier("pane-last-prompt-copy")
                .accessibilityLabel(copied ? "Prompt copied" : "Copy prompt")
            }

            Rectangle()
                .fill(HerdrTheme.surface)
                .frame(height: 1)

            ScrollView {
                PiMarkdownText(message.text, font: HerdrTheme.scaled(.body, scale: fontScale))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            }
            .scrollIndicators(.visible)
        }
        .padding(HerdrTheme.cardPadding)
        .frame(width: 420, height: 360, alignment: .topLeading)
        .background(HerdrTheme.graphite, in: RoundedRectangle(cornerRadius: HerdrTheme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                .stroke(HerdrTheme.surface, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: HerdrTheme.cardRadius))
    }

    @ViewBuilder
    private func timestampCaption(for message: PiUserMessage) -> some View {
        if let timestamp = message.timestamp {
            Text("what you asked · \(timestamp, style: .relative)")
                .herdrFont(.caption, monospaced: true)
                .foregroundStyle(HerdrTheme.mist)
        } else {
            Text("what you asked")
                .herdrFont(.caption, monospaced: true)
                .foregroundStyle(HerdrTheme.mist)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            copied = false
        }
    }
}
