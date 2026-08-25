import Testing
@testable import herdr_harness_mac

@Suite("Pi chat motion structure")
struct PiChatMotionStructureTests {
    @Test("Streaming token deltas do not trigger structural motion")
    func tokenDeltasKeepStructureStable() {
        let initial = turn(text: "Hel", status: .streaming)
        let streamed = turn(text: "Hello", status: .streaming)
        let completed = turn(text: "Hello", status: .complete)

        #expect(PiChatTurnStructure(turn: initial) == PiChatTurnStructure(turn: streamed))
        #expect(PiChatTurnStructure(turn: streamed) == PiChatTurnStructure(turn: completed))
    }

    @Test("New transcript items trigger structural motion")
    func newItemChangesStructure() {
        let initial = turn(text: "I will check.", status: .complete)
        var withTool = initial
        withTool.items.append(
            .tool(
                PiToolInvocation(
                    id: "tool:1",
                    callID: "call-1",
                    name: "read",
                    arguments: nil,
                    result: nil,
                    status: .running,
                    startedAt: nil,
                    finishedAt: nil
                )
            )
        )
        withTool.itemsRevision += 1

        #expect(PiChatTurnStructure(turn: initial) != PiChatTurnStructure(turn: withTool))
    }

    @Test("Tool output deltas keep timeline structure stable")
    func toolOutputDeltasKeepTimelineStructureStable() {
        var initial = turn(text: "I will check.", status: .complete)
        initial.items.append(
            .tool(
                PiToolInvocation(
                    id: "tool:1",
                    callID: "call-1",
                    name: "read",
                    arguments: nil,
                    result: .string("first chunk"),
                    status: .running,
                    startedAt: nil,
                    finishedAt: nil
                )
            )
        )
        var streamed = initial
        streamed.items[1] = .tool(
            PiToolInvocation(
                id: "tool:1",
                callID: "call-1",
                name: "read",
                arguments: nil,
                result: .string("first chunk and second chunk"),
                status: .running,
                startedAt: nil,
                finishedAt: nil
            )
        )

        #expect(PiChatTurnStructure(turn: initial) == PiChatTurnStructure(turn: streamed))
    }

    private func turn(text: String, status: PiAssistantBlock.Status) -> PiConversationTurn {
        PiConversationTurn(
            id: "turn:1",
            user: PiUserMessage(id: "user:1", text: "Check this", timestamp: nil),
            items: [
                .assistant(
                    PiAssistantBlock(
                        id: "assistant:1",
                        text: text,
                        status: status,
                        timestamp: nil
                    )
                )
            ],
            startedAt: nil,
            isActive: status == .streaming
        )
    }
}
