import SwiftUI
import Testing
@testable import herdr_harness_ios

@Suite("Pi markdown inline-code styling")
struct PiMarkdownInlineCodeStylingTests {
    @Test("Only inline-code runs receive the color")
    func stylesOnlyCodeRuns() {
        let source = "use `foo` now and `bar`"
        let rendered = PiMarkdownText.render(source)
        let styled = PiMarkdownText.applyingInlineCodeStyle(
            rendered,
            font: .system(size: 13, weight: .medium, design: .monospaced),
            color: .red
        )

        var sawCodeRun = false
        for run in styled.runs {
            let isCode = run.inlinePresentationIntent?.contains(.code) == true
            if isCode {
                sawCodeRun = true
                #expect(run.foregroundColor == .red)
                #expect(run.backgroundColor == nil)
            } else {
                #expect(run.foregroundColor == nil)
                #expect(run.backgroundColor == nil)
            }
        }
        #expect(sawCodeRun)
    }

    @Test("A string with no inline code round-trips unchanged")
    func plainTextRoundTrips() {
        let source = "no code spans here, just plain text"
        let rendered = PiMarkdownText.render(source)
        let styled = PiMarkdownText.applyingInlineCodeStyle(
            rendered,
            font: .system(size: 13, weight: .medium, design: .monospaced),
            color: .red
        )

        #expect(String(styled.characters) == String(rendered.characters))
        for run in styled.runs {
            #expect(run.foregroundColor == nil)
            #expect(run.backgroundColor == nil)
        }
    }
}
