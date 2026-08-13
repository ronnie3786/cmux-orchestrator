import SwiftUI

struct PiMarkdownText: View {
    let source: String
    let font: Font

    init(_ source: String, font: Font = .body) {
        self.source = source
        self.font = font
    }

    var body: some View {
        Text(rendered)
            .font(font)
            .foregroundStyle(HerdrTheme.text)
            .tint(HerdrTheme.accent)
            .textSelection(.enabled)
    }

    private var rendered: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
    }
}
