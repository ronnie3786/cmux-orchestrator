import SwiftUI

struct PiMarkdownMessageView: View {
    let source: String
    let isStreaming: Bool
    private let blocks: [PiMarkdownBlock]

    init(source: String, isStreaming: Bool) {
        self.source = source
        self.isStreaming = isStreaming
        blocks = isStreaming ? [] : PiMarkdownParser.parse(source)
    }

    var body: some View {
        if isStreaming {
            PiMarkdownText(source)
                .lineSpacing(3)
        } else {
            VStack(alignment: .leading, spacing: 11) {
                ForEach(blocks) { block in
                    PiMarkdownBlockView(block: block)
                }
            }
        }
    }
}
