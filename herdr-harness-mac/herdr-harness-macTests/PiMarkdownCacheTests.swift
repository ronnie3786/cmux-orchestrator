import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("Pi markdown caches")
struct PiMarkdownCacheTests {
    @Test("Identity and length keys reuse entries without crossing identities")
    func identityAndLengthKeysRemainDistinct() throws {
        let inlineCache = PiMarkdownInlineCache.shared
        let documentCache = PiMarkdownDocumentCache.shared
        let firstID = "inline-cache-first"
        let secondID = "inline-cache-second"
        let firstSource = "alpha"
        let secondSource = "bravo"

        _ = inlineCache.rendered(firstSource, id: firstID, cacheKeyLength: firstSource.utf8.count)
        let firstEntry = try #require(
            inlineCache.renderedEntry(for: firstSource, id: firstID, cacheKeyLength: firstSource.utf8.count)
        )
        _ = inlineCache.rendered(firstSource, id: firstID, cacheKeyLength: firstSource.utf8.count)
        let reusedEntry = try #require(
            inlineCache.renderedEntry(for: firstSource, id: firstID, cacheKeyLength: firstSource.utf8.count)
        )
        _ = inlineCache.rendered(secondSource, id: secondID, cacheKeyLength: secondSource.utf8.count)
        let secondEntry = try #require(
            inlineCache.renderedEntry(for: secondSource, id: secondID, cacheKeyLength: secondSource.utf8.count)
        )

        #expect(firstEntry === reusedEntry)
        #expect(firstEntry !== secondEntry)
        #expect(String(secondEntry.value.characters) == secondSource)

        let firstBlocks = documentCache.blocks(for: "first", id: "document-cache-first")
        let firstDocumentEntry = try #require(documentCache.entry(for: "first", id: "document-cache-first"))
        _ = documentCache.blocks(for: "first", id: "document-cache-first")
        let reusedDocumentEntry = try #require(documentCache.entry(for: "first", id: "document-cache-first"))
        let secondBlocks = documentCache.blocks(for: "other", id: "document-cache-second")
        let secondDocumentEntry = try #require(documentCache.entry(for: "other", id: "document-cache-second"))
        #expect(firstBlocks == [.paragraph(id: 0, text: "first")])
        #expect(secondBlocks == [.paragraph(id: 0, text: "other")])
        #expect(firstDocumentEntry === reusedDocumentEntry)
        #expect(firstDocumentEntry !== secondDocumentEntry)
    }

    @Test("Evicting streaming entries removes parsed and styled snapshots")
    func evictsStreamingEntries() {
        let inlineCache = PiMarkdownInlineCache.shared
        let documentCache = PiMarkdownDocumentCache.shared
        let inlineID = "inline-cache-eviction"
        let documentID = "document-cache-eviction"
        let source = "Use `value`"
        let length = source.utf8.count
        let font = Font.system(size: 13, weight: .medium, design: .monospaced)

        inlineCache.markStreamingEntry(id: inlineID, length: length)
        let rendered = inlineCache.rendered(source, id: inlineID, cacheKeyLength: length)
        _ = inlineCache.styled(rendered, source: source, font: font, color: .red, id: inlineID, cacheKeyLength: length)
        documentCache.markStreamingEntry(id: documentID, length: length)
        _ = documentCache.blocks(for: source, id: documentID)

        #expect(inlineCache.renderedEntry(for: source, id: inlineID, cacheKeyLength: length) != nil)
        #expect(inlineCache.styledEntry(for: source, font: font, color: .red, id: inlineID, cacheKeyLength: length) != nil)
        #expect(documentCache.entry(for: source, id: documentID) != nil)

        inlineCache.evictStreaming(id: inlineID)
        documentCache.evictStreaming(id: documentID)

        #expect(inlineCache.renderedEntry(for: source, id: inlineID, cacheKeyLength: length) == nil)
        #expect(inlineCache.styledEntry(for: source, font: font, color: .red, id: inlineID, cacheKeyLength: length) == nil)
        #expect(documentCache.entry(for: source, id: documentID) == nil)
    }

    @Test("Styled cache keys include inline-code font scale")
    func styledCacheInvalidatesForFontScale() throws {
        let cache = PiMarkdownInlineCache.shared
        let source = "Use `value`"
        let id = "inline-cache-font-scale"
        let length = source.utf8.count
        let smallFont = HerdrProse.inlineCodeFont(.body, scale: .small)
        let largeFont = HerdrProse.inlineCodeFont(.body, scale: .xxxLarge)
        let rendered = cache.rendered(source, id: id, cacheKeyLength: length)

        let smallStyled = cache.styled(
            rendered,
            source: source,
            font: smallFont,
            color: HerdrProse.inlineCodeColor,
            id: id,
            cacheKeyLength: length
        )
        let smallEntry = try #require(
            cache.styledEntry(
                for: source,
                font: smallFont,
                color: HerdrProse.inlineCodeColor,
                id: id,
                cacheKeyLength: length
            )
        )
        let largeStyled = cache.styled(
            rendered,
            source: source,
            font: largeFont,
            color: HerdrProse.inlineCodeColor,
            id: id,
            cacheKeyLength: length
        )
        let largeEntry = try #require(
            cache.styledEntry(
                for: source,
                font: largeFont,
                color: HerdrProse.inlineCodeColor,
                id: id,
                cacheKeyLength: length
            )
        )

        #expect(smallEntry !== largeEntry)
        #expect(inlineCodeFont(in: smallStyled) == smallFont)
        #expect(inlineCodeFont(in: largeStyled) == largeFont)
    }

    private func inlineCodeFont(in source: AttributedString) -> Font? {
        for run in source.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                return run.font
            }
        }
        return nil
    }
}
