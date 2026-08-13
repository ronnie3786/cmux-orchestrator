import SwiftUI

struct PiMarkdownBlockView: View {
    let block: PiMarkdownBlock

    var body: some View {
        switch block {
        case let .paragraph(_, text):
            PiMarkdownText(text)
                .lineSpacing(3)
        case let .code(_, language, code):
            PiCodeBlockView(language: language, code: code)
        case let .bullet(_, text):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text("•")
                    .foregroundStyle(HerdrTheme.accent)
                    .accessibilityHidden(true)
                PiMarkdownText(text)
            }
        case let .numbered(_, number, text):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text("\(number).")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(HerdrTheme.accent)
                    .accessibilityHidden(true)
                PiMarkdownText(text)
            }
        case let .quote(_, text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(HerdrTheme.mauve.opacity(0.72))
                    .frame(width: 3)
                    .accessibilityHidden(true)
                PiMarkdownText(text)
                    .italic()
                    .foregroundStyle(HerdrTheme.mist)
            }
        }
    }
}
