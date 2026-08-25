import os
import SwiftUI

struct PiMarkdownText: View {
    let source: String
    let font: Font
    let cacheRenderedText: Bool
    var inlineCodeFont: Font? = nil
    var inlineCodeColor: Color? = nil
    let id: String?
    let cacheKeyLength: Int?

    init(
        _ source: String,
        font: Font = .body,
        cacheRenderedText: Bool = true,
        inlineCodeFont: Font? = nil,
        inlineCodeColor: Color? = nil,
        id: String? = nil,
        cacheKeyLength: Int? = nil
    ) {
        self.source = source
        self.font = font
        self.cacheRenderedText = cacheRenderedText
        self.inlineCodeFont = inlineCodeFont
        self.inlineCodeColor = inlineCodeColor
        self.id = id
        self.cacheKeyLength = cacheKeyLength
    }

    var body: some View {
        let rendered: AttributedString
        if cacheRenderedText {
            rendered = PiMarkdownInlineCache.shared.rendered(
                source,
                id: id,
                cacheKeyLength: cacheKeyLength
            )
        } else {
            rendered = Self.render(source)
        }

        let styled: AttributedString
        if let inlineCodeFont, let inlineCodeColor {
            styled = cacheRenderedText
                ? PiMarkdownInlineCache.shared.styled(
                    rendered,
                    source: source,
                    font: inlineCodeFont,
                    color: inlineCodeColor,
                    id: id,
                    cacheKeyLength: cacheKeyLength
                )
                : Self.applyingInlineCodeStyle(rendered, font: inlineCodeFont, color: inlineCodeColor)
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

    static func applyingInlineCodeStyle(_ source: AttributedString, font: Font, color: Color) -> AttributedString {
        var result = source
        var codeRanges: [Range<AttributedString.Index>] = []
        for run in result.runs {
            guard let intent = run.inlinePresentationIntent, intent.contains(.code) else { continue }
            codeRanges.append(run.range)
        }
        for range in codeRanges {
            result[range].font = font
            result[range].foregroundColor = color
        }
        return result
    }
}

final class PiMarkdownInlineCache: @unchecked Sendable {
    static let shared = PiMarkdownInlineCache()

    final class Entry {
        let value: AttributedString

        init(value: AttributedString) {
            self.value = value
        }
    }

    private let renderedCache = NSCache<NSString, Entry>()
    private let styledCache = NSCache<NSString, Entry>()
    private let streamingKeysLock = OSAllocatedUnfairLock<[String: Set<String>]>(initialState: [:])

    private init() {
        renderedCache.countLimit = 2_048
        renderedCache.totalCostLimit = 16 * 1_024 * 1_024
        styledCache.countLimit = 2_048
        styledCache.totalCostLimit = 16 * 1_024 * 1_024
    }

    func markStreamingEntry(id: String, length: Int) {
        streamingKeysLock.withLock { keys in
            keys[id, default: []].insert(Self.identityKey(id: id, length: length))
        }
    }

    func evictStreaming(id: String) {
        let keys = streamingKeysLock.withLock { $0.removeValue(forKey: id) } ?? []
        for key in keys {
            renderedCache.removeObject(forKey: key as NSString)
            styledCache.removeObject(forKey: key as NSString)
        }
    }

    func rendered(
        _ source: String,
        id: String? = nil,
        cacheKeyLength: Int? = nil
    ) -> AttributedString {
        let key = Self.renderedKey(for: source, id: id, cacheKeyLength: cacheKeyLength)
        if let cached = renderedCache.object(forKey: key as NSString) {
            return cached.value
        }
        let value = Self.render(source)
        renderedCache.setObject(Entry(value: value), forKey: key as NSString, cost: source.utf8.count)
        return value
    }

    func styled(
        _ rendered: AttributedString,
        source: String,
        font: Font,
        color: Color,
        id: String? = nil,
        cacheKeyLength: Int? = nil
    ) -> AttributedString {
        let key = Self.styledKey(
            for: source,
            font: font,
            color: color,
            id: id,
            cacheKeyLength: cacheKeyLength
        )
        if let cached = styledCache.object(forKey: key as NSString) {
            recordStyledStreamingKey(key, id: id, cacheKeyLength: cacheKeyLength ?? source.utf8.count)
            return cached.value
        }
        let value = PiMarkdownText.applyingInlineCodeStyle(rendered, font: font, color: color)
        styledCache.setObject(Entry(value: value), forKey: key as NSString, cost: source.utf8.count)
        recordStyledStreamingKey(key, id: id, cacheKeyLength: cacheKeyLength ?? source.utf8.count)
        return value
    }

    func renderedEntry(
        for source: String,
        id: String? = nil,
        cacheKeyLength: Int? = nil
    ) -> Entry? {
        renderedCache.object(forKey: Self.renderedKey(for: source, id: id, cacheKeyLength: cacheKeyLength) as NSString)
    }

    func styledEntry(
        for source: String,
        font: Font,
        color: Color,
        id: String? = nil,
        cacheKeyLength: Int? = nil
    ) -> Entry? {
        styledCache.object(
            forKey: Self.styledKey(
                for: source,
                font: font,
                color: color,
                id: id,
                cacheKeyLength: cacheKeyLength
            ) as NSString
        )
    }

    static func render(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
    }

    private func recordStyledStreamingKey(_ key: String, id: String?, cacheKeyLength: Int) {
        guard let id else { return }
        streamingKeysLock.withLock { keys in
            guard keys[id]?.contains(Self.identityKey(id: id, length: cacheKeyLength)) == true else { return }
            keys[id, default: []].insert(key)
        }
    }

    private static func renderedKey(for source: String, id: String?, cacheKeyLength: Int?) -> String {
        if let id {
            identityKey(id: id, length: cacheKeyLength ?? source.utf8.count)
        } else {
            source
        }
    }

    private static func identityKey(id: String, length: Int) -> String {
        "identity\u{0}\(id)\u{0}\(length)"
    }

    private static func styledKey(
        for source: String,
        font: Font,
        color: Color,
        id: String?,
        cacheKeyLength: Int?
    ) -> String {
        var hasher = Hasher()
        hasher.combine(font)
        hasher.combine(color)
        let baseKey: String
        if let id {
            baseKey = identityKey(id: id, length: cacheKeyLength ?? source.utf8.count)
        } else {
            baseKey = source
        }
        return "\(baseKey)\u{0}style\u{0}\(hasher.finalize())"
    }
}
