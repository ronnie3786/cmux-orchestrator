import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Terminal grid hardening")
struct TerminalGridHardeningTests {
    @Test("Full base64 ANSI frame clears and positions the cursor")
    func fullFrameWithCursorPositioning() {
        var grid = TerminalGrid(columns: 8, rows: 3)
        let frame = terminalFrame(
            "\u{001B}[2J\u{001B}[HABC\u{001B}[2;3HZ",
            full: true,
            sequence: 1,
            width: 8,
            height: 3
        )

        let applied = grid.apply(frame)
        #expect(applied)
        #expect(grid.columns == 8)
        #expect(grid.rows == 3)
        #expect(grid.plainText == "ABC\n  Z")
    }

    @Test("Delta frame updates cells without erasing the previous frame")
    func deltaPreservesPriorCells() {
        var grid = TerminalGrid(columns: 5, rows: 2)

        let fullApplied = grid.apply(
            terminalFrame(
                "hello\r\nworld",
                full: true,
                sequence: 10,
                width: 5,
                height: 2
            )
        )
        #expect(fullApplied)
        let deltaApplied = grid.apply(
            terminalFrame(
                "\u{001B}[1;2HX",
                full: false,
                sequence: 11,
                width: 5,
                height: 2
            )
        )
        #expect(deltaApplied)

        #expect(grid.plainText == "hXllo\nworld")
    }

    @Test("Grid exposes its configured dimensions")
    func gridDimensions() {
        let grid = TerminalGrid(columns: 132, rows: 41)

        #expect(grid.columns == 132)
        #expect(grid.rows == 41)
        #expect(grid.plainText.isEmpty)
    }

    @Test("Invalid base64 is rejected without mutating visible cells")
    func invalidBase64IsNonDestructive() {
        var grid = TerminalGrid(columns: 4, rows: 1)
        let seedApplied = grid.apply(
            terminalFrame(
                "safe",
                full: true,
                sequence: 20,
                width: 4,
                height: 1
            )
        )
        #expect(seedApplied)
        let previousText = grid.plainText

        let invalidFrame = TerminalFrame(
            bytes: "%%% definitely-not-base64 %%%",
            encoding: "base64",
            full: false,
            height: 1,
            sequence: 21,
            type: "terminal.frame",
            width: 4
        )

        let invalidApplied = grid.apply(invalidFrame)
        #expect(!invalidApplied)
        #expect(grid.plainText == previousText)
        #expect(grid.columns == 4)
        #expect(grid.rows == 1)
    }

    @Test("Plain HTTP is limited to the local machine")
    func serverConfigurationTransportSecurity() {
        #expect(ServerConfiguration(urlString: "http://workstation.example:9092", token: "token") == nil)
        #expect(ServerConfiguration(urlString: "http://workstation.tailnet.ts.net:9092", token: "token") == nil)

        #expect(ServerConfiguration(urlString: "http://localhost:9092", token: "token") != nil)

        #expect(ServerConfiguration(urlString: "https://workstation.tailnet.ts.net", token: "token") != nil)
    }

    private func terminalFrame(
        _ text: String,
        full: Bool,
        sequence: Int,
        width: Int,
        height: Int
    ) -> TerminalFrame {
        TerminalFrame(
            bytes: Data(text.utf8).base64EncodedString(),
            encoding: "base64",
            full: full,
            height: height,
            sequence: sequence,
            type: "terminal.frame",
            width: width
        )
    }
}
