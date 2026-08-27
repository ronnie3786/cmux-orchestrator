import SwiftUI

struct PiMarkdownTableLayout: Equatable, Sendable {
    static let baseMinimumColumnWidth: CGFloat = 140

    let viewportWidth: CGFloat
    let columnCount: Int
    let fontScale: HerdrFontScale

    var columnWidth: CGFloat {
        guard columnCount > 0 else { return 0 }
        return max(minimumColumnWidth, max(0, viewportWidth) / CGFloat(columnCount))
    }

    var contentWidth: CGFloat {
        columnWidth * CGFloat(max(0, columnCount))
    }

    private var minimumColumnWidth: CGFloat {
        Self.baseMinimumColumnWidth * CGFloat(fontScale.rawValue)
    }
}
