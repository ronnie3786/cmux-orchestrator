import Foundation
import Testing
@testable import herdr_harness_mac

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

    @Test("Model capabilities accept snake case, camel case, and absent fields")
    func decodesModelCapabilities() throws {
        let snakeCase = try JSONDecoder().decode(
            PiSemanticCapabilities.self,
            from: Data("{\"prompt\":true,\"list_models\":true,\"set_model\":true,\"set_thinking_level\":true}".utf8)
        )
        let camelCase = try JSONDecoder().decode(
            PiSemanticCapabilities.self,
            from: Data("{\"prompt\":true,\"listModels\":true,\"setModel\":true,\"setThinkingLevel\":true}".utf8)
        )
        let absent = try JSONDecoder().decode(
            PiSemanticCapabilities.self,
            from: Data("{\"prompt\":true}".utf8)
        )

        #expect(snakeCase.listModels)
        #expect(snakeCase.setModel)
        #expect(snakeCase.setThinkingLevel)
        #expect(camelCase.listModels)
        #expect(camelCase.setModel)
        #expect(camelCase.setThinkingLevel)
        #expect(!absent.listModels)
        #expect(!absent.setModel)
        #expect(!absent.setThinkingLevel)
        #expect(!PiSemanticCapabilities.unavailable.listModels)
        #expect(!PiSemanticCapabilities.unavailable.setModel)
        #expect(!PiSemanticCapabilities.unavailable.setThinkingLevel)
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
                  "latest_cursor":18,
                  "oldest_cursor":"3",
                  "truncated":true
                }
                """.utf8
            )
        )

        #expect(snapshot.paneID == "w1:p1")
        #expect(snapshot.cursor == "17")
        #expect(snapshot.latestCursor == "18")
        #expect(snapshot.oldestCursor == "3")
        #expect(snapshot.truncated)
        #expect(snapshot.entries.first?["payload"]?["x"]?.stringValue == "1")
        #expect(!snapshot.reportsContextUsage)
    }

    @Test("Context telemetry presence distinguishes legacy snapshots")
    func detectsContextTelemetry() throws {
        let snapshot = try JSONDecoder().decode(
            PiConversationSnapshot.self,
            from: Data(
                """
                {
                  "protocol":{"name":"herdr.pi.semantic","version":1},
                  "paneId":"p1","available":true,"connected":true,
                  "state":{"isStreaming":false,"context":{"tokens":null,"contextWindow":192000,"percent":null}},
                  "entries":[],"pendingInteractions":[],"cursor":"1","truncated":false
                }
                """.utf8
            )
        )

        // The field exists even when individual values are temporarily null.
        // This is how the app distinguishes a new bridge from a legacy one.
        #expect(snapshot.reportsContextUsage)
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
