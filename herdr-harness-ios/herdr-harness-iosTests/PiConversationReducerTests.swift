import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Pi conversation reducer")
struct PiConversationReducerTests {
    @MainActor
    @Test("A reset exits a still-open stream so follow can reload its snapshot")
    func resetInterruptsLiveStream() async throws {
        let reset = try envelope(
            1,
            "{\"type\":\"stream.reset\",\"reason\":\"session_tree_changed\"}"
        )
        let stream = AsyncThrowingStream<PiConversationStreamEvent, any Error> { continuation in
            continuation.yield(.activity)
            continuation.yield(.envelope(reset))
            // Deliberately keep the stream open. A production SSE connection
            // will not end just because it delivered a reset record.
        }
        let store = PiConversationStore()

        #expect(try await store.consume(stream))
    }

    @Test("Pi turn start waits for the user message before creating a visible turn")
    func turnStartDoesNotCreateOrphanTurn() {
        var reducer = PiConversationReducer()
        let start = PiConversationEnvelope(
            paneID: "w1:p1",
            sessionID: "session-a",
            cursor: "1",
            event: .object(["type": .string("turn_start")])
        )

        _ = reducer.apply(start)

        #expect(reducer.phase == .working)
        #expect(reducer.turns.isEmpty)
    }

    @Test("Tree and compaction lifecycle events reload same-session context")
    func contextReplacementRequestsSnapshot() {
        for eventType in ["session_tree", "session_compact"] {
            var reducer = PiConversationReducer()
            let envelope = PiConversationEnvelope(
                paneID: "w1:p1",
                sessionID: "session-a",
                cursor: "1",
                event: .object(["type": .string(eventType)])
            )

            #expect(reducer.apply(envelope) == .needsSnapshot)
        }
    }

    @Test("Snapshot groups persisted entries into stable user turns")
    func projectsSnapshotIntoTurns() throws {
        let snapshot = try decodeSnapshot(
            entries: """
            [
              {
                "type":"message","id":"u1","parentId":null,"timestamp":"2026-08-12T12:00:00Z",
                "message":{"role":"user","content":"Inspect the API","timestamp":1786536000000}
              },
              {
                "type":"message","id":"a1","parentId":"u1","timestamp":"2026-08-12T12:00:01Z",
                "message":{
                  "role":"assistant","timestamp":1786536001000,"stopReason":"toolUse",
                  "content":[
                    {"type":"thinking","thinking":"I should inspect the file."},
                    {"type":"text","text":"I’ll inspect it."},
                    {"type":"toolCall","id":"call-1","name":"read","arguments":{"path":"API.swift"}}
                  ]
                }
              },
              {
                "type":"message","id":"r1","parentId":"a1","timestamp":"2026-08-12T12:00:02Z",
                "message":{
                  "role":"toolResult","toolCallId":"call-1","toolName":"read","isError":false,
                  "timestamp":1786536002000,"content":[{"type":"text","text":"contents"}]
                }
              },
              {
                "type":"message","id":"a2","parentId":"r1","timestamp":"2026-08-12T12:00:03Z",
                "message":{
                  "role":"assistant","timestamp":1786536003000,"stopReason":"stop",
                  "content":[{"type":"text","text":"The API looks good."}]
                }
              },
              {
                "type":"message","id":"u2","parentId":"a2","timestamp":"2026-08-12T12:01:00Z",
                "message":{"role":"user","content":"Thanks","timestamp":1786536060000}
              }
            ]
            """
        )
        var reducer = PiConversationReducer()
        reducer.replace(with: snapshot)

        #expect(reducer.turns.count == 2)
        #expect(reducer.turns[0].id == "turn:u1")
        #expect(reducer.turns[0].user?.text == "Inspect the API")
        #expect(reducer.turns[0].items.count == 4)
        #expect(reducer.turns[1].user?.text == "Thanks")
        #expect(reducer.phase == .idle)

        let tool = reducer.turns[0].items.compactMap { item -> PiToolInvocation? in
            guard case let .tool(value) = item else { return nil }
            return value
        }.first
        #expect(tool?.status == .succeeded)
        #expect(tool?.arguments?["path"]?.stringValue == "API.swift")
    }

    @Test("Direct stripped deltas stream text, thinking, and tools without duplication")
    func reducesDirectDeltas() throws {
        var reducer = PiConversationReducer()
        reducer.replace(with: try decodeSnapshot(entries: "[]", state: "{\"isStreaming\":true}"))

        #expect(reducer.apply(try envelope(1, "{\"type\":\"agent_start\"}")) == .none)
        #expect(reducer.apply(try envelope(2, """
        {"type":"message_start","message":{"role":"assistant","timestamp":1786536000000,"content":[]}}
        """)) == .none)
        _ = reducer.apply(try envelope(3, """
        {"type":"message_update","assistantMessageEvent":{"type":"text_start","contentIndex":0}}
        """))
        let delta = try envelope(4, """
        {"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"Hello"}}
        """)
        _ = reducer.apply(delta)
        _ = reducer.apply(delta)
        _ = reducer.apply(try envelope(5, """
        {"type":"message_update","assistantMessageEvent":{"type":"thinking_start","contentIndex":1}}
        """))
        _ = reducer.apply(try envelope(6, """
        {"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","contentIndex":1,"delta":"Checking"}}
        """))
        _ = reducer.apply(try envelope(7, """
        {"type":"message_update","assistantMessageEvent":{"type":"thinking_end","contentIndex":1,"content":"Checking carefully"}}
        """))
        _ = reducer.apply(try envelope(8, """
        {"type":"message_update","assistantMessageEvent":{"type":"toolcall_start","contentIndex":2}}
        """))
        _ = reducer.apply(try envelope(9, """
        {"type":"message_update","assistantMessageEvent":{"type":"toolcall_end","contentIndex":2,"toolCall":{"type":"toolCall","id":"call-2","name":"bash","arguments":{"command":"pwd"}}}}
        """))
        _ = reducer.apply(try envelope(10, """
        {"type":"tool_execution_start","toolCallId":"call-2","toolName":"bash","args":{"command":"pwd"}}
        """))
        _ = reducer.apply(try envelope(11, """
        {"type":"tool_execution_end","toolCallId":"call-2","toolName":"bash","result":{"content":"/repo"},"isError":false}
        """))
        _ = reducer.apply(try envelope(12, """
        {
          "type":"message_end",
          "message":{"role":"assistant","timestamp":1786536000000,"stopReason":"stop","content":[
            {"type":"text","text":"Hello!"},
            {"type":"thinking","thinking":"Checking carefully"},
            {"type":"toolCall","id":"call-2","name":"bash","arguments":{"command":"pwd"}}
          ]}
        }
        """))
        let settledEffect = reducer.apply(try envelope(13, "{\"type\":\"agent_settled\"}"))

        #expect(settledEffect == .completed)
        #expect(reducer.phase == .idle)
        #expect(reducer.turns.count == 1)
        let items = reducer.turns[0].items
        let text = items.compactMap { item -> PiAssistantBlock? in
            guard case let .assistant(value) = item else { return nil }
            return value
        }.first
        let thinking = items.compactMap { item -> PiThinkingBlock? in
            guard case let .thinking(value) = item else { return nil }
            return value
        }.first
        let tool = items.compactMap { item -> PiToolInvocation? in
            guard case let .tool(value) = item else { return nil }
            return value
        }.first
        #expect(text?.text == "Hello!")
        #expect(thinking?.text == "Checking carefully")
        #expect(thinking?.isStreaming == false)
        #expect(tool?.callID == "call-2")
        #expect(tool?.status == .succeeded)
        #expect(tool?.result?["content"]?.stringValue == "/repo")
    }

    @Test("Replay gaps request an authoritative snapshot")
    func resetsForReplayGap() throws {
        var reducer = PiConversationReducer()
        reducer.replace(with: try decodeSnapshot(entries: "[]"))
        _ = reducer.apply(try envelope(9, "{\"type\":\"ready\",\"connected\":true}"))
        let effect = reducer.apply(
            try envelope(9, "{\"type\":\"stream.reset\",\"reason\":\"replay_gap\"}")
        )
        #expect(effect == .needsSnapshot)
    }

    @Test("Only bridge state events change command connectivity")
    func tracksBridgeConnectivity() throws {
        var reducer = PiConversationReducer()
        let offlineSnapshot = try JSONDecoder().decode(
            PiConversationSnapshot.self,
            from: Data(
                """
                {
                  "protocol":{"name":"herdr.pi.semantic","version":1},
                  "paneId":"p1","available":true,"connected":false,
                  "entries":[],"pendingInteractions":[],"cursor":"0","truncated":false
                }
                """.utf8
            )
        )
        reducer.replace(with: offlineSnapshot)
        #expect(!reducer.bridgeConnected)

        _ = reducer.apply(try envelope(1, "{\"type\":\"agent_start\"}"))
        #expect(!reducer.bridgeConnected)

        _ = reducer.apply(try envelope(2, "{\"type\":\"bridge.connection\",\"connected\":true}"))
        #expect(reducer.bridgeConnected)

        _ = reducer.apply(try envelope(3, "{\"type\":\"bridge.connection\",\"connected\":false}"))
        #expect(!reducer.bridgeConnected)
        #expect(reducer.turns.isEmpty)
    }

    @Test("An empty failed assistant message remains visible")
    func projectsFailureWithoutText() throws {
        var reducer = PiConversationReducer()
        reducer.replace(with: try decodeSnapshot(entries: "[]"))

        let effect = reducer.apply(
            try envelope(1, """
            {
              "type":"message_end",
              "message":{
                "role":"assistant",
                "id":"a-error",
                "content":[],
                "stopReason":"error",
                "errorMessage":"Provider unavailable"
              }
            }
            """)
        )

        #expect(effect == .failed)
        #expect(reducer.turns.last?.items.contains(where: { item in
            guard case let .notice(notice) = item else { return false }
            return notice.detail == "Provider unavailable" && notice.tone == .error
        }) == true)
    }

    @Test("Pending extension interactions are correlated and removed")
    func projectsInteraction() throws {
        var reducer = PiConversationReducer()
        reducer.replace(with: try decodeSnapshot(entries: "[]"))
        let requested = reducer.apply(
            try envelope(1, """
            {
              "type":"extension_ui_request",
              "id":"question-1",
              "method":"select",
              "title":"Choose a target",
              "options":["iOS","Server"]
            }
            """)
        )

        #expect(requested == .interactionRequested)
        #expect(reducer.pendingInteractions.first?.options == ["iOS", "Server"])
        reducer.removeInteraction(id: "question-1")
        #expect(reducer.pendingInteractions.isEmpty)
    }

    @Test("Context usage projects from snapshots and updates on turn end")
    func contextUsageProjectsFromSnapshotAndTurnEnd() throws {
        var reducer = PiConversationReducer()

        let snapshot = try decodeSnapshot(
            entries: "[]",
            state: "{\"isStreaming\":false,\"context\":{\"tokens\":12345,\"contextWindow\":192000,\"percent\":6.43}}"
        )
        reducer.replace(with: snapshot)
        #expect(reducer.contextUsage?.tokens == 12345)
        #expect(reducer.contextUsage?.contextWindow == 192000)
        #expect(reducer.contextUsage?.fraction == 12345.0 / 192000)

        let turnEnd = try envelope(
            1,
            "{\"type\":\"turn_end\",\"turnIndex\":1,\"context\":{\"tokens\":20000,\"contextWindow\":192000,\"percent\":10.4}}"
        )
        _ = reducer.apply(turnEnd)
        #expect(reducer.contextUsage?.tokens == 20000)

        // A null post-compaction reading keeps the last known value.
        let compactedTurnEnd = try envelope(
            2,
            "{\"type\":\"turn_end\",\"turnIndex\":2,\"context\":{\"tokens\":null,\"contextWindow\":null,\"percent\":null}}"
        )
        _ = reducer.apply(compactedTurnEnd)
        #expect(reducer.contextUsage?.tokens == 20000)

        // An authoritative snapshot still wins, including "unknown".
        let compactedSnapshot = try decodeSnapshot(
            entries: "[]",
            state: "{\"isStreaming\":false,\"context\":{\"tokens\":null,\"contextWindow\":null,\"percent\":null}}"
        )
        reducer.replace(with: compactedSnapshot)
        #expect(reducer.contextUsage == nil)
    }

    @Test("Older snapshots without context reporting leave usage unknown")
    func missingContextStaysUnknown() throws {
        var reducer = PiConversationReducer()
        let snapshot = try decodeSnapshot(entries: "[]")
        reducer.replace(with: snapshot)
        #expect(reducer.contextUsage == nil)
    }

    private func decodeSnapshot(
        entries: String,
        state: String = "{\"isStreaming\":false}"
    ) throws -> PiConversationSnapshot {
        try JSONDecoder().decode(
            PiConversationSnapshot.self,
            from: Data(
                """
                {
                  "protocol":{"name":"herdr.pi.semantic","version":1},
                  "paneId":"p1","available":true,"connected":true,
                  "session":{"id":"s1"},"state":\(state),"entries":\(entries),
                  "pendingInteractions":[],"cursor":"0","oldestCursor":"0","truncated":false
                }
                """.utf8
            )
        )
    }

    private func envelope(_ cursor: Int, _ eventJSON: String) throws -> PiConversationEnvelope {
        let event = try JSONDecoder().decode(PiJSONValue.self, from: Data(eventJSON.utf8))
        return PiConversationEnvelope(
            paneID: "p1",
            sessionID: "s1",
            cursor: String(cursor),
            event: event
        )
    }
}
