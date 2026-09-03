import SwiftUI

struct PiUserMessageView: View {
    let message: PiUserMessage
    @Environment(\.herdrFontScale) private var fontScale
    @State private var labelCache = PiUserMessageLabelCache()

    var body: some View {
        let accessibilityLabel = labelCache.accessibilityLabel(for: message)
        // A trailing-aligned frame instead of `HStack { Spacer; bubble }`: the
        // stack would size-probe the bubble at several widths per layout pass.
        PiMarkdownText(message.text, font: HerdrTheme.scaled(.body, scale: fontScale))
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(HerdrTheme.surface.opacity(0.82), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(HerdrTheme.accent.opacity(0.16), lineWidth: 1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            // Attached to the bubble rather than the row: the row is full width,
            // so a row-level overlay strands the control at the far left while
            // the bubble hugs the right. Offset into the leading gutter the
            // 42pt pad already reserves, so it never sits over the text.
            .piCopyAffordance(
                message.text,
                label: "Copy prompt",
                identifier: "pi-user-copy-\(message.id)",
                alignment: .topLeading,
                offset: CGSize(width: -28, height: 4)
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 42)
    }
}

private final class PiUserMessageLabelCache {
    private var id: String?
    private var source: String?
    private var label: String?

    func accessibilityLabel(for message: PiUserMessage) -> String {
        if id == message.id, source == message.text, let label {
            return label
        }
        let label = "You: \(message.text)"
        id = message.id
        source = message.text
        self.label = label
        return label
    }
}
