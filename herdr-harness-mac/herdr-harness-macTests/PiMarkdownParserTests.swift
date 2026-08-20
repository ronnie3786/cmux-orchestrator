import Testing
@testable import herdr_harness_mac

@Suite("Pi Markdown blocks")
struct PiMarkdownParserTests {
    @Test("Parses coding-agent block structure without a dependency")
    func parsesBlocks() {
        let blocks = PiMarkdownParser.parse(
            """
            Intro with **emphasis** and [a link](https://example.com).

            - one
            2. two
            > note

            ```swift
            let value = 42
            print(value)
            ```
            """
        )

        #expect(blocks.count == 4)
        #expect(
            blocks[0] == .paragraph(
                id: 0,
                text: "Intro with **emphasis** and [a link](https://example.com)."
            )
        )
        #expect(
            blocks[1] == .list(
                id: 1,
                items: [
                    PiMarkdownListItem(marker: .bullet, text: "one", depth: 0),
                    PiMarkdownListItem(marker: .number("2"), text: "two", depth: 0),
                ]
            )
        )
        #expect(blocks[2] == .quote(id: 2, text: "note"))
        #expect(blocks[3] == .code(id: 3, language: "swift", code: "let value = 42\nprint(value)"))
    }

    @Test("Parses GitHub-style tables with alignment and inline pipes")
    func parsesTable() {
        let blocks = PiMarkdownParser.parse(
            #"""
            | Command | State | Cost |
            | :--- | :---: | ---: |
            | `build|test` | **ready** | $4 |
            | escaped \| pipe | waiting | 9 |
            """#
        )

        #expect(
            blocks == [
                .table(
                    id: 0,
                    table: PiMarkdownTable(
                        headers: ["Command", "State", "Cost"],
                        alignments: [.leading, .center, .trailing],
                        rows: [
                            ["`build|test`", "**ready**", "$4"],
                            [#"escaped \| pipe"#, "waiting", "9"],
                        ]
                    )
                )
            ]
        )
    }

    @Test("Normalizes short and long table rows")
    func normalizesTableRows() {
        let blocks = PiMarkdownParser.parse(
            """
            A | B
            --- | ---
            one
            one | two | ignored
            """
        )

        // A row must contain a pipe, so the first line after the delimiter ends the table.
        #expect(
            blocks == [
                .table(
                    id: 0,
                    table: PiMarkdownTable(
                        headers: ["A", "B"],
                        alignments: [.leading, .leading],
                        rows: []
                    )
                ),
                .paragraph(id: 1, text: "one\none | two | ignored"),
            ]
        )
    }

    @Test("Parses ATX and setext headings plus thematic breaks")
    func parsesHeadingsAndRule() {
        let blocks = PiMarkdownParser.parse(
            """
            # Summary **today** ##

            Results
            ===

            ---

            ###### Detail
            """
        )

        #expect(
            blocks == [
                .heading(id: 0, level: 1, text: "Summary **today**"),
                .heading(id: 1, level: 1, text: "Results"),
                .thematicBreak(id: 2),
                .heading(id: 3, level: 6, text: "Detail"),
            ]
        )
    }

    @Test("Does not treat a hash without whitespace as a heading")
    func rejectsFalseHeading() {
        let blocks = PiMarkdownParser.parse("#include <stdio.h>")
        #expect(blocks == [.paragraph(id: 0, text: "#include <stdio.h>")])
    }

    @Test("Groups quote lines and preserves quote paragraph spacing")
    func parsesQuote() {
        let blocks = PiMarkdownParser.parse(
            """
            > First **point**
            >
            > Second point
            """
        )
        #expect(blocks == [.quote(id: 0, text: "First **point**\n\nSecond point")])
    }

    @Test("Parses tasks, nesting, ordered markers, and continuation text")
    func parsesLists() {
        let blocks = PiMarkdownParser.parse(
            """
            - [x] shipped
            - [ ] pending
                - nested **child**
                    - deep child
            1) first
               continued explanation
            """
        )

        #expect(
            blocks == [
                .list(
                    id: 0,
                    items: [
                        PiMarkdownListItem(marker: .task(isCompleted: true), text: "shipped", depth: 0),
                        PiMarkdownListItem(marker: .task(isCompleted: false), text: "pending", depth: 0),
                        PiMarkdownListItem(marker: .bullet, text: "nested **child**", depth: 1),
                        PiMarkdownListItem(marker: .bullet, text: "deep child", depth: 2),
                        PiMarkdownListItem(
                            marker: .number("1"),
                            text: "first\ncontinued explanation",
                            depth: 0
                        ),
                    ]
                )
            ]
        )
    }

    @Test("Supports tilde fences and uses the first info token as the language")
    func parsesTildeFence() {
        let blocks = PiMarkdownParser.parse(
            """
            ~~~~typescript title=sample
            const value = `ok`;
            ~~~~~
            """
        )
        #expect(
            blocks == [
                .code(id: 0, language: "typescript", code: "const value = `ok`;")
            ]
        )
    }

    @Test("An unfinished fence remains readable while streaming")
    func parsesUnfinishedFence() {
        let blocks = PiMarkdownParser.parse("```sh\necho ready")
        #expect(blocks == [.code(id: 0, language: "sh", code: "echo ready")])
    }

    @Test("Empty and whitespace-only messages have no blocks")
    func parsesEmptySource() {
        #expect(PiMarkdownParser.parse("").isEmpty)
        #expect(PiMarkdownParser.parse(" \n\t").isEmpty)
    }
}
