import SwiftUI

struct PiMarkdownBlockView: View {
    let block: PiMarkdownBlock

    var body: some View {
        switch block {
        case let .paragraph(_, text):
            PiMarkdownText(text)
                .lineSpacing(3)
        case let .heading(_, level, text):
            PiMarkdownText(text, font: headingFont(level))
                .lineSpacing(2)
                .accessibilityAddTraits(.isHeader)
        case let .code(_, language, code):
            PiCodeBlockView(language: language, code: code)
        case let .list(_, items):
            PiMarkdownListView(items: items)
        case let .quote(_, text):
            PiMarkdownText(text)
                .lineSpacing(3)
                .italic()
                .foregroundStyle(HerdrTheme.mist)
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(HerdrTheme.mauve.opacity(0.72))
                    .frame(width: 3)
                    .accessibilityHidden(true)
                }
        case let .table(_, table):
            PiMarkdownTableView(table: table)
        case .thematicBreak:
            Rectangle()
                .fill(HerdrTheme.surface.opacity(0.82))
                .frame(height: 1)
                .padding(.vertical, 3)
                .accessibilityHidden(true)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.bold)
        case 2: .title3.weight(.bold)
        case 3: .headline.weight(.bold)
        case 4: .subheadline.weight(.semibold)
        case 5: .footnote.weight(.bold)
        default: .caption.weight(.bold)
        }
    }
}
