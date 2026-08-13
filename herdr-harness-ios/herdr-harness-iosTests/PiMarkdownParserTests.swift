import Testing
@testable import herdr_harness_ios

@Suite("Pi Markdown blocks")
struct PiMarkdownParserTests {
    @Test("Parses coding-agent block structure without a dependency")
    func parsesBlocks() {
        let blocks = PiMarkdownParser.parse(
            """
            Intro with **emphasis**.

            - one
            2. two
            > note

            ```swift
            let value = 42
            print(value)
            ```
            """
        )

        #expect(blocks.count == 5)
        #expect(blocks[0] == .paragraph(id: 0, text: "Intro with **emphasis**."))
        #expect(blocks[1] == .bullet(id: 1, text: "one"))
        #expect(blocks[2] == .numbered(id: 2, number: "2", text: "two"))
        #expect(blocks[3] == .quote(id: 3, text: "note"))
        #expect(blocks[4] == .code(id: 4, language: "swift", code: "let value = 42\nprint(value)"))
    }

    @Test("An unfinished fence remains readable while streaming")
    func parsesUnfinishedFence() {
        let blocks = PiMarkdownParser.parse("```sh\necho ready")
        #expect(blocks == [.code(id: 0, language: "sh", code: "echo ready")])
    }
}
