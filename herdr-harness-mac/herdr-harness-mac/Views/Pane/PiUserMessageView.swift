import SwiftUI

struct PiUserMessageView: View {
    let message: PiUserMessage
    @Environment(\.herdrFontScale) private var fontScale

    var body: some View {
        HStack {
            Spacer(minLength: 42)
            PiMarkdownText(message.text, font: HerdrTheme.scaled(.body, scale: fontScale))
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(HerdrTheme.surface.opacity(0.82), in: RoundedRectangle(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(HerdrTheme.accent.opacity(0.16), lineWidth: 1)
                }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You: \(message.text)")
    }
}
