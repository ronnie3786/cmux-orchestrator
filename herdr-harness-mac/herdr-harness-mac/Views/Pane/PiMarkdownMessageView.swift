import os
import SwiftUI

struct PiMarkdownMessageView: View {
    let source: String
    let isStreaming: Bool
    let id: String?
    @Environment(\.herdrFontScale) private var fontScale

    init(source: String, isStreaming: Bool, id: String? = nil) {
        self.source = source
        self.isStreaming = isStreaming
        self.id = id
    }

    var body: some View {
        Group {
            if isStreaming {
                streamingContent(
                    split: PiMarkdownParser.splitStreamingTail(source),
                    fullSourceLength: source.utf8.count
                )
            } else {
                finalizedContent()
            }
        }
        .onChange(of: isStreaming) { wasStreaming, isStreaming in
            guard wasStreaming, !isStreaming, let id else { return }
            PiMarkdownDocumentCache.shared.evictStreaming(id: id)
            PiMarkdownInlineCache.shared.evictStreaming(id: id)
        }
    }

    private func streamingContent(
        split: PiMarkdownParser.StreamingSplit,
        fullSourceLength: Int
    ) -> some View {
        if let id {
            if !split.prefix.isEmpty {
                PiMarkdownDocumentCache.shared.markStreamingEntry(
                    id: id,
                    length: split.prefix.utf8.count
                )
            }
            PiMarkdownInlineCache.shared.markStreamingEntry(id: id, length: fullSourceLength)
        }

        let blocks = split.prefix.isEmpty
            ? []
            : PiMarkdownDocumentCache.shared.blocks(for: split.prefix, id: id)
        return VStack(alignment: .leading, spacing: HerdrProse.blockSpacing) {
            ForEach(blocks) { block in
                PiMarkdownBlockView(block: block, isFirst: block.id == blocks.first?.id)
            }
            PiMarkdownText(
                split.tail,
                font: HerdrProse.font(.body, scale: fontScale),
                inlineCodeFont: HerdrProse.inlineCodeFont(.body, scale: fontScale),
                inlineCodeColor: HerdrProse.inlineCodeColor,
                id: id,
                cacheKeyLength: fullSourceLength
            )
                .lineSpacing(HerdrProse.lineSpacing(.body, scale: fontScale))
        }
    }

    private func finalizedContent() -> some View {
        let blocks = PiMarkdownDocumentCache.shared.blocks(for: source, id: id)
        return VStack(alignment: .leading, spacing: HerdrProse.blockSpacing) {
            ForEach(blocks) { block in
                PiMarkdownBlockView(block: block, isFirst: block.id == blocks.first?.id)
            }
        }
    }
}

final class PiMarkdownDocumentCache: @unchecked Sendable {
    static let shared = PiMarkdownDocumentCache()

    final class Entry {
        let blocks: [PiMarkdownBlock]

        init(blocks: [PiMarkdownBlock]) {
            self.blocks = blocks
        }
    }

    private let cache = NSCache<NSString, Entry>()
    private let streamingKeysLock = OSAllocatedUnfairLock<[String: Set<String>]>(initialState: [:])

    private init() {
        cache.countLimit = 512
        cache.totalCostLimit = 16 * 1_024 * 1_024
    }

    func markStreamingEntry(id: String, length: Int) {
        streamingKeysLock.withLock { keys in
            keys[id, default: []].insert(Self.identityKey(id: id, length: length))
        }
    }

    func evictStreaming(id: String) {
        let keys = streamingKeysLock.withLock { $0.removeValue(forKey: id) } ?? []
        for key in keys {
            cache.removeObject(forKey: key as NSString)
        }
    }

    func blocks(for source: String, id: String? = nil) -> [PiMarkdownBlock] {
        let key = Self.cacheKey(for: source, id: id)
        if let cached = cache.object(forKey: key as NSString) {
            return cached.blocks
        }
        let blocks = PiMarkdownParser.parse(source)
        cache.setObject(Entry(blocks: blocks), forKey: key as NSString, cost: source.utf8.count)
        return blocks
    }

    func entry(for source: String, id: String? = nil) -> Entry? {
        cache.object(forKey: Self.cacheKey(for: source, id: id) as NSString)
    }

    private static func cacheKey(for source: String, id: String?) -> String {
        if let id {
            identityKey(id: id, length: source.utf8.count)
        } else {
            source
        }
    }

    private static func identityKey(id: String, length: Int) -> String {
        "identity\u{0}\(id)\u{0}\(length)"
    }
}
