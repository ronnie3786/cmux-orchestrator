import SwiftUI

struct PiMarkdownMessageView: View {
    let source: String
    let isStreaming: Bool
    private let blocks: [PiMarkdownBlock]
    @Environment(\.herdrFontScale) private var fontScale

    init(source: String, isStreaming: Bool) {
        self.source = source
        self.isStreaming = isStreaming
        blocks = isStreaming ? [] : PiMarkdownDocumentCache.shared.blocks(for: source)
    }

    var body: some View {
        if isStreaming {
            PiMarkdownText(
                source,
                font: HerdrTheme.scaled(.body, scale: fontScale),
                cacheRenderedText: false
            )
                .lineSpacing(3)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(blocks) { block in
                    PiMarkdownBlockView(block: block)
                }
            }
        }
    }
}

private final class PiMarkdownDocumentCache: @unchecked Sendable {
    static let shared = PiMarkdownDocumentCache()

    private final class Entry {
        let blocks: [PiMarkdownBlock]

        init(blocks: [PiMarkdownBlock]) {
            self.blocks = blocks
        }
    }

    private let cache = NSCache<NSString, Entry>()

    private init() {
        cache.countLimit = 96
        cache.totalCostLimit = 2 * 1_024 * 1_024
    }

    func blocks(for source: String) -> [PiMarkdownBlock] {
        let key = source as NSString
        if let cached = cache.object(forKey: key) {
            return cached.blocks
        }
        let blocks = PiMarkdownParser.parse(source)
        cache.setObject(Entry(blocks: blocks), forKey: key, cost: source.utf8.count)
        return blocks
    }
}
