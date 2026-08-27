import CoreFoundation
import Testing
@testable import herdr_harness_mac

@Suite("Pi markdown table layout")
struct PiMarkdownTableLayoutTests {
    @Test("Few columns divide the available width evenly")
    func fillsViewport() {
        let layout = PiMarkdownTableLayout(
            viewportWidth: 720,
            columnCount: 2,
            fontScale: .medium
        )

        #expect(layout.columnWidth == 360)
        #expect(layout.contentWidth == 720)
    }

    @Test("Dense tables preserve readable columns and overflow horizontally")
    func preservesMinimumColumnWidth() {
        let layout = PiMarkdownTableLayout(
            viewportWidth: 720,
            columnCount: 8,
            fontScale: .medium
        )

        #expect(layout.columnWidth == PiMarkdownTableLayout.baseMinimumColumnWidth)
        #expect(layout.contentWidth == 1_120)
    }

    @Test("Minimum width follows the user's Herdr text scale")
    func scalesMinimumColumnWidth() {
        let layout = PiMarkdownTableLayout(
            viewportWidth: 320,
            columnCount: 3,
            fontScale: .xxLarge
        )

        #expect(abs(layout.columnWidth - 196) < 0.001)
        #expect(abs(layout.contentWidth - 588) < 0.001)
    }

    @Test("An empty table has no synthetic width")
    func handlesNoColumns() {
        let layout = PiMarkdownTableLayout(
            viewportWidth: 720,
            columnCount: 0,
            fontScale: .medium
        )

        #expect(layout.columnWidth == 0)
        #expect(layout.contentWidth == 0)
    }
}
