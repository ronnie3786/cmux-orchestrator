import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Pi timeline rows")
struct PiTimelineRowTests {
    @Test("Turns flatten into one row per user message, output item, and working group")
    func flattensTurnsIntoRows() {
        let turns = [
            turn(id: "turn:1", items: [
                .thinking(thinking(id: "t1")),
                .tool(tool(id: "c1")),
                .assistant(assistant(id: "a1", text: "First answer")),
            ]),
            turn(id: "turn:2", items: [
                .assistant(assistant(id: "a2", text: "Second answer")),
            ], isActive: true),
        ]

        let rows = PiTimelineRow.rows(for: turns)

        #expect(rows.map(\.id) == [
            "turn:1|user",
            "turn:1|working:t1",
            "turn:1|output:a1",
            "turn:2|user",
            "turn:2|output:a2",
        ])
        #expect(rows.map(\.startsTurn) == [true, false, false, true, false])
        #expect(rows.map(\.isFirstInTimeline) == [true, false, false, false, false])
        #expect(rows.map(\.rail.isFirst) == [true, false, false, true, false])
        #expect(rows.map(\.rail.isLast) == [false, false, true, false, true])
        #expect(rows[0].topSpacing == 0)
        #expect(rows[1].topSpacing == PiTimelineMetrics.itemSpacing)
        #expect(rows[3].topSpacing == HerdrProse.turnSpacing)
        #expect(rows[0].rail.hasTool)
        #expect(!rows[3].rail.hasTool)
        #expect(rows[3].rail.isActive)
    }

    @Test("An active turn with no items gets the starting placeholder row")
    func activeEmptyTurnShowsStartingRow() {
        let rows = PiTimelineRow.rows(for: [turn(id: "turn:1", items: [], isActive: true)])

        #expect(rows.map(\.id) == ["turn:1|user", "turn:1|starting"])
        #expect(rows.last?.content == .starting)
        #expect(rows.last?.rail.isLast == true)
    }

    @Test("A turn with nothing visible produces no rows")
    func invisibleTurnProducesNoRows() {
        var empty = turn(id: "turn:1", items: [])
        empty.user = nil

        #expect(PiTimelineRow.rows(for: [empty]).isEmpty)
    }

    @Test("Streaming a token changes exactly the row that owns the text")
    func tokenChangesOnlyItsRow() {
        let before = [
            turn(id: "turn:1", items: [
                .thinking(thinking(id: "t1")),
                .assistant(assistant(id: "a1", text: "Hel", status: .streaming)),
            ], isActive: true),
        ]
        var after = before
        after[0].items[1] = .assistant(assistant(id: "a1", text: "Hello", status: .streaming))
        after[0].itemsRevision += 1

        let rowsBefore = PiTimelineRow.rows(for: before)
        let rowsAfter = PiTimelineRow.rows(for: after)

        #expect(rowsBefore.count == 3)
        #expect(rowsBefore[0] == rowsAfter[0])
        #expect(rowsBefore[1] == rowsAfter[1])
        #expect(rowsBefore[2] != rowsAfter[2])
    }

    @MainActor
    @Test("Row views compare by row content so unchanged rows skip their body")
    func rowViewEquatableFollowsRowModel() {
        let rows = PiTimelineRow.rows(for: [turn(id: "turn:1", items: [.assistant(assistant(id: "a1", text: "Hi"))])])
        let view = PiTimelineRowView(row: rows[1])
        let same = PiTimelineRowView(row: rows[1])
        var changedRows = PiTimelineRow.rows(for: [turn(id: "turn:1", items: [.assistant(assistant(id: "a1", text: "Hi there"))])])
        let changed = PiTimelineRowView(row: changedRows.removeLast())

        #expect(view == same)
        #expect(view != changed)
    }

    @Test("Failure and activity state flow into every row's rail")
    func railCarriesTurnState() {
        let failed = turn(id: "turn:1", items: [
            .assistant(assistant(id: "a1", text: "ok")),
            .tool(tool(id: "c1", status: .failed)),
        ])
        let rows = PiTimelineRow.rows(for: [failed])

        #expect(rows.allSatisfy { $0.rail.hasFailure })
        #expect(rows.allSatisfy { $0.rail.hasTool })
        #expect(rows.allSatisfy { !$0.rail.isActive })
    }

    private func turn(id: String, items: [PiConversationItem], isActive: Bool = false) -> PiConversationTurn {
        PiConversationTurn(
            id: id,
            user: PiUserMessage(id: "\(id):user", text: "Prompt", timestamp: nil),
            items: items,
            itemsRevision: 1,
            startedAt: nil,
            isActive: isActive
        )
    }

    private func assistant(id: String, text: String, status: PiAssistantBlock.Status = .complete) -> PiAssistantBlock {
        PiAssistantBlock(id: id, text: text, status: status, timestamp: nil)
    }

    private func thinking(id: String) -> PiThinkingBlock {
        PiThinkingBlock(id: id, text: "Thinking", isStreaming: false, isRedacted: false, startedAt: nil)
    }

    private func tool(id: String, status: PiToolInvocation.Status = .succeeded) -> PiToolInvocation {
        PiToolInvocation(
            id: "tool:\(id)",
            callID: id,
            name: "bash",
            arguments: nil,
            result: nil,
            status: status,
            startedAt: nil,
            finishedAt: nil
        )
    }
}
