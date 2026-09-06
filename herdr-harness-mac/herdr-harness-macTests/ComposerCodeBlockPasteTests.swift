import AppKit
import Testing
@testable import herdr_harness_mac

@Suite("Code block paste")
struct ComposerCodeBlockPasteTests {
    @Test("Keeps literal fences and clipboard whitespace")
    func preservesText() {
        #expect(ComposerCodeBlockPaste.fenced("  let value = 1\n") == "```\n  let value = 1\n```")
        #expect(ComposerCodeBlockPaste.fenced("hello") == "```\nhello\n```")
        #expect(ComposerCodeBlockPaste.fenced("```swift\nx\n```") == "````\n```swift\nx\n```\n````")
    }

    @Test("Inserts at selection with line boundaries and UTF-16 indices")
    func insertsAtCaret() {
        #expect(ComposerCodeBlockPaste.inserting("code", into: "before after", selection: NSRange(location: 7, length: 0)) == "before \n```\ncode\n```\nafter")
        #expect(ComposerCodeBlockPaste.inserting("x", into: "👋 old", selection: NSRange(location: 3, length: 3)) == "👋 \n```\nx\n```")
        #expect(ComposerCodeBlockPaste.inserting("x", into: "hello", selection: NSRange(location: 50, length: 0)) == "hello")
    }

    @MainActor
    @Test("Reads only clipboard text and reports an empty clipboard")
    func clipboard() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var draft = "Review this:"
        #expect(!ComposerCodeBlockPaste.paste(into: &draft, pasteboard: board))
        board.setString("let safe = true", forType: .string)
        #expect(ComposerCodeBlockPaste.paste(into: &draft, pasteboard: board))
        #expect(draft == "Review this:\n```\nlet safe = true\n```")
    }
}
