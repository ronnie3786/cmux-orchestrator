import Testing

#if os(iOS)
@testable import herdr_harness_ios
#elseif os(macOS)
@testable import herdr_harness_mac
#endif

@Suite("Pi last prompt")
struct PiLastPromptTests {
    @Test("Returns the user message from the latest completed user turn")
    func returnsLatestCompletedUserTurn() {
        let earlier = PiUserMessage(id: "user-1", text: "Inspect the API", timestamp: nil)
        let latest = PiUserMessage(id: "user-2", text: "Run the tests", timestamp: nil)
        let turns = [
            PiConversationTurn(
                id: "turn-1",
                user: earlier,
                items: [],
                startedAt: nil,
                isActive: false
            ),
            PiConversationTurn(
                id: "turn-2",
                user: latest,
                items: [
                    .assistant(PiAssistantBlock(
                        id: "assistant-2",
                        text: "I will run them.",
                        status: .complete,
                        timestamp: nil
                    )),
                ],
                startedAt: nil,
                isActive: false
            ),
        ]

        #expect(PiLastPrompt.lastUserMessage(in: turns) == latest)
    }

    @Test("Returns an in-flight prompt as soon as it echoes")
    func returnsInFlightPromptEcho() {
        let prompt = PiUserMessage(id: "user-1", text: "Explain this failure", timestamp: nil)
        let turns = [
            PiConversationTurn(
                id: "turn-1",
                user: prompt,
                items: [],
                startedAt: nil,
                isActive: true
            ),
        ]

        #expect(PiLastPrompt.lastUserMessage(in: turns) == prompt)
    }

    @Test("Returns nil for an empty transcript")
    func returnsNilForEmptyTranscript() {
        #expect(PiLastPrompt.lastUserMessage(in: []) == nil)
    }

    @Test("Skips a trailing orphan assistant turn")
    func skipsTrailingAssistantOnlyTurn() {
        let prompt = PiUserMessage(id: "user-1", text: "Summarize the logs", timestamp: nil)
        let turns = [
            PiConversationTurn(
                id: "turn-1",
                user: prompt,
                items: [],
                startedAt: nil,
                isActive: false
            ),
            PiConversationTurn(
                id: "orphan-2",
                user: nil,
                items: [
                    .assistant(PiAssistantBlock(
                        id: "assistant-2",
                        text: "An orphan response",
                        status: .complete,
                        timestamp: nil
                    )),
                ],
                startedAt: nil,
                isActive: false
            ),
        ]

        #expect(PiLastPrompt.lastUserMessage(in: turns) == prompt)
    }
}
