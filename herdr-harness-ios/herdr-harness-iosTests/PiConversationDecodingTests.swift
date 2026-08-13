import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Pi semantic protocol decoding")
struct PiConversationDecodingTests {
    @Test("Pane capability decodes the v1 feature contract")
    func decodesPaneCapability() throws {
        let pane = try JSONDecoder().decode(
            HerdrPane.self,
            from: Data(
                """
                {
                  "pane_id": "w1:p1",
                  "workspace_id": "w1",
                  "tab_id": "w1:t1",
                  "agent_status": "working",
                  "pi_semantic": {
                    "available": true,
                    "connected": true,
                    "protocolVersion": 1,
                    "sessionId": "session-1",
                    "cursor": 42,
                    "oldestCursor": "8",
                    "capabilities": {
                      "prompt": true,
                      "steer": true,
                      "followUp": true,
                      "abort": true,
                      "interactionResponse": true
                    }
                  }
                }
                """.utf8
            )
        )

        #expect(pane.supportsPiSemanticChat)
        #expect(pane.piSemantic?.sessionID == "session-1")
        #expect(pane.piSemantic?.cursor == "42")
        #expect(pane.piSemantic?.capabilities.followUp == true)
    }

    @Test("Snapshot retains unknown entries and accepts snake case aliases")
    func decodesSnapshotForwardCompatibly() throws {
        let snapshot = try JSONDecoder().decode(
            PiConversationSnapshot.self,
            from: Data(
                """
                {
                  "protocol": {"name":"herdr.pi.semantic","version":1},
                  "pane_id":"w1:p1",
                  "available":true,
                  "connected":true,
                  "session":{"id":"s1","future":"kept"},
                  "entries":[{"type":"future_entry","id":"e1","payload":{"x":1}}],
                  "pending_interactions":[],
                  "cursor":17,
                  "oldest_cursor":"3",
                  "truncated":true
                }
                """.utf8
            )
        )

        #expect(snapshot.paneID == "w1:p1")
        #expect(snapshot.cursor == "17")
        #expect(snapshot.oldestCursor == "3")
        #expect(snapshot.truncated)
        #expect(snapshot.entries.first?["payload"]?["x"]?.stringValue == "1")
    }

    @Test("SSE parser preserves durable id and multiline payload")
    func parsesDurableSSEEvent() throws {
        var parser = PiConversationSSEParser()
        #expect(try parser.consume(line: "id: 82") == nil)
        #expect(try parser.consume(line: "event: pi.agent_start") == nil)
        #expect(try parser.consume(line: "data: {\"protocol\":{\"name\":\"herdr.pi.semantic\",\"version\":1},") == nil)
        let output = try parser.consume(
            line: "data: \"paneId\":\"p1\",\"sessionId\":\"s1\",\"event\":{\"type\":\"agent_start\"}}"
        )
        guard case let .envelope(envelope) = output else {
            Issue.record("Expected a Pi envelope")
            return
        }
        #expect(envelope.cursor == "82")
        #expect(envelope.eventType == "agent_start")
        #expect(envelope.sessionID == "s1")
    }

    @Test("SSE comments and heartbeat frames count as activity")
    func parsesActivity() throws {
        var parser = PiConversationSSEParser()
        #expect(try parser.consume(line: ": keepalive") == .activity)
        #expect(try parser.consume(line: "event: heartbeat") == nil)
        #expect(try parser.consume(line: "data: {}") == .activity)
        #expect(try parser.consume(line: "") == nil)
    }

    @Test("SSE accepts the server's namespaced ready event")
    func parsesNamespacedReady() throws {
        var parser = PiConversationSSEParser()
        #expect(try parser.consume(line: "event: pi.ready") == nil)
        #expect(
            try parser.consume(line: "data: {\"cursor\":\"42\",\"latest_cursor\":\"47\"}") == .activity
        )
        #expect(try parser.consume(line: "") == nil)
    }

    @Test("Command acknowledgement accepts bridge success responses")
    func decodesCommandAcknowledgement() throws {
        let response = try JSONDecoder().decode(
            PiCommandResponse.self,
            from: Data("{\"type\":\"response\",\"success\":true}".utf8)
        )
        #expect(response.accepted)
    }
}
