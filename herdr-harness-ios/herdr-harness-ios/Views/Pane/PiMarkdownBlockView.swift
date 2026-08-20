import SwiftUI

struct PiMarkdownBlockView: View {
    let block: PiMarkdownBlock
    var isFirst: Bool = false

    var body: some View {
        switch block {
        case let .paragraph(_, text):
            PiMarkdownText(
                text,
                font: HerdrProse.font(.body),
                inlineCodeFont: HerdrProse.inlineCodeFont(.body),
                inlineCodeBackground: HerdrProse.inlineCodeBackground
            )
                .lineSpacing(HerdrProse.lineSpacing(.body))
        case let .heading(_, level, text):
            PiMarkdownText(
                text,
                font: headingFont(level),
                inlineCodeFont: HerdrProse.inlineCodeFont(headingRole(level)),
                inlineCodeBackground: HerdrProse.inlineCodeBackground
            )
                .lineSpacing(2)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, isFirst ? 0 : HerdrProse.headingTopSpacing(level))
        case let .code(_, language, code):
            PiCodeBlockView(language: language, code: code)
        case let .list(_, items):
            PiMarkdownListView(items: items)
        case let .quote(_, text):
            PiMarkdownText(
                text,
                font: HerdrProse.font(.quote),
                inlineCodeFont: HerdrProse.inlineCodeFont(.quote),
                inlineCodeBackground: HerdrProse.inlineCodeBackground
            )
                .lineSpacing(HerdrProse.lineSpacing(.quote))
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
                .padding(.vertical, 10)
                .accessibilityHidden(true)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: HerdrProse.font(.heading1)
        case 2: HerdrProse.font(.heading2)
        case 3: HerdrProse.font(.heading3)
        case 4: HerdrProse.font(.heading4)
        case 5: HerdrProse.font(.heading5)
        default: HerdrProse.font(.heading6)
        }
    }

    private func headingRole(_ level: Int) -> HerdrProse.Role {
        switch level {
        case 1: .heading1
        case 2: .heading2
        case 3: .heading3
        case 4: .heading4
        case 5: .heading5
        default: .heading6
        }
    }
}
