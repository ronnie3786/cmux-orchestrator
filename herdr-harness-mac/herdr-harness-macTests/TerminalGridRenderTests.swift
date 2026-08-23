import Foundation
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("Terminal grid rendering")
struct TerminalGridRenderTests {
    @Test("Hoisted font resolution preserves ANSI run attributes")
    func hoistedFontsMatchPerRunReference() {
        var grid = TerminalGrid(columns: 32, rows: 1)
        let applied = grid.apply(frame("\u{001B}[1mB\u{001B}[3mI\u{001B}[4mU\u{001B}[31mR\u{001B}[0mN\u{001B}[?25l"))
        #expect(applied)

        #expect(grid.attributedText() == oldPerRunReference())
    }

    @Test("A dense terminal remains inexpensive to render")
    func denseGridRenderPerformance() {
        var grid = TerminalGrid(columns: 100, rows: 32)
        var payload = "\u{001B}[?25l"
        for index in 0..<(100 * 32) {
            payload += "\u{001B}[\(31 + index % 7);\(index.isMultiple(of: 3) ? 1 : 22);\(index.isMultiple(of: 5) ? 3 : 23)m•"
        }
        let applied = grid.apply(frame(payload))
        #expect(applied)

        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<20 {
            _ = grid.attributedText()
        }
        let elapsed = start.duration(to: clock.now)
        let milliseconds = Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        #expect(milliseconds / 20 < 30, "average render was \(milliseconds / 20) ms")
    }

    private func oldPerRunReference() -> AttributedString {
        let defaultFont = HerdrTheme.scaled(.footnote, scale: .default, monospaced: true)
        let red = Color(red: 205.0 / 255, green: 49.0 / 255, blue: 49.0 / 255)
        let runs: [(String, Color, Bool, Bool, Bool)] = [
            ("B", HerdrTheme.text, true, false, false),
            ("I", HerdrTheme.text, true, true, false),
            ("U", HerdrTheme.text, true, true, true),
            ("R", red, true, true, true),
            ("N", HerdrTheme.text, false, false, false),
        ]
        var result = AttributedString()
        for (text, color, bold, italic, underline) in runs {
            var value = AttributedString(text)
            value.foregroundColor = color
            var font = defaultFont
            if bold { font = font.bold() }
            if italic { font = font.italic() }
            value.font = font
            if underline { value.underlineStyle = .single }
            result.append(value)
        }
        return result
    }

    private func frame(_ text: String) -> TerminalFrame {
        TerminalFrame(
            bytes: Data(text.utf8).base64EncodedString(),
            encoding: "base64",
            full: true,
            height: 1,
            sequence: 1,
            type: "terminal.frame",
            width: 100
        )
    }
}
