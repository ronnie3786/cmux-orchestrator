import SwiftUI

struct PiMarkdownBlockView: View {
    let block: PiMarkdownBlock
    @Environment(\.herdrFontScale) private var fontScale

    var body: some View {
        switch block {
        case let .paragraph(_, text):
            PiMarkdownText(text, font: HerdrProse.font(.body, scale: fontScale))
                .lineSpacing(HerdrProse.lineSpacing(.body, scale: fontScale))
        case let .heading(_, level, text):
            PiMarkdownText(text, font: headingFont(level))
                .lineSpacing(2)
                .accessibilityAddTraits(.isHeader)
        case let .code(_, language, code):
            PiCodeBlockView(language: language, code: code)
        case let .list(_, items):
            PiMarkdownListView(items: items)
        case let .quote(_, text):
            PiMarkdownText(text, font: HerdrProse.font(.quote, scale: fontScale))
                .lineSpacing(HerdrProse.lineSpacing(.quote, scale: fontScale))
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
        case 1: HerdrProse.font(.heading1, scale: fontScale)
        case 2: HerdrProse.font(.heading2, scale: fontScale)
        case 3: HerdrProse.font(.heading3, scale: fontScale)
        case 4: HerdrProse.font(.heading4, scale: fontScale)
        case 5: HerdrProse.font(.heading5, scale: fontScale)
        default: HerdrProse.font(.heading6, scale: fontScale)
        }
    }
}
