import SwiftUI

struct PiMarkdownText: View {
    let source: String
    let font: Font
    var inlineCodeFont: Font? = nil
    var inlineCodeBackground: Color? = nil
    private let rendered: AttributedString

    init(
        _ source: String,
        font: Font = .body,
        cacheRenderedText: Bool = true,
        inlineCodeFont: Font? = nil,
        inlineCodeBackground: Color? = nil
    ) {
        self.source = source
        self.font = font
        self.inlineCodeFont = inlineCodeFont
        self.inlineCodeBackground = inlineCodeBackground
        rendered = cacheRenderedText
            ? PiMarkdownInlineCache.shared.rendered(source)
            : PiMarkdownInlineCache.render(source)
    }

    var body: some View {
        let styled: AttributedString
        if let inlineCodeFont, let inlineCodeBackground {
            styled = Self.applyingInlineCodeStyle(rendered, font: inlineCodeFont, background: inlineCodeBackground)
        } else {
            styled = rendered
        }
        return Text(styled)
            .font(font)
            .foregroundStyle(HerdrTheme.text)
            .tint(HerdrTheme.accent)
            .textSelection(.enabled)
    }

    static func render(_ source: String) -> AttributedString {
        PiMarkdownInlineCache.render(source)
    }

    static func applyingInlineCodeStyle(_ source: AttributedString, font: Font, background: Color) -> AttributedString {
        var result = source
        for run in result.runs {
            guard let intent = run.inlinePresentationIntent, intent.contains(.code) else { continue }
            result[run.range].font = font
            result[run.range].backgroundColor = background
        }
        return result
    }
}

private final class PiMarkdownInlineCache: @unchecked Sendable {
    static let shared = PiMarkdownInlineCache()

    private final class Entry {
        let value: AttributedString

        init(value: AttributedString) {
            self.value = value
        }
    }

    private let cache = NSCache<NSString, Entry>()

    private init() {
        cache.countLimit = 384
        cache.totalCostLimit = 2 * 1_024 * 1_024
    }

    func rendered(_ source: String) -> AttributedString {
        let key = source as NSString
        if let cached = cache.object(forKey: key) {
            return cached.value
        }
        let value = Self.render(source)
        cache.setObject(Entry(value: value), forKey: key, cost: source.utf8.count)
        return value
    }

    static func render(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
    }
}
