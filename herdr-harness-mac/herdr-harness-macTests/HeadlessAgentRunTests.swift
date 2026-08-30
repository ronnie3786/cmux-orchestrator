import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Headless Agent contract")
struct HeadlessAgentRunTests {
    @Test("Decodes the asynchronous run envelope and promotion route")
    func decodesRunEnvelope() throws {
        let data = Data(#"""
        {
          "ok": true,
          "run": {
            "id": "run-1",
            "status": "promoted",
            "prompt": "What needs me?",
            "response": "One pane is blocked.",
            "error": null,
            "createdAt": "2026-08-25T12:00:00Z",
            "startedAt": "2026-08-25T12:00:01Z",
            "finishedAt": "2026-08-25T12:00:02Z",
            "sessionId": "session-1",
            "sessionFile": "/private/session.jsonl",
            "costUSD": 0.012,
            "promotedWorkspaceId": "w1",
            "promotedPaneId": "w1:p2"
          }
        }
        """#.utf8)

        let envelope = try JSONDecoder().decode(HeadlessAgentRunEnvelope.self, from: data)

        #expect(envelope.ok)
        #expect(envelope.run.status == .promoted)
        #expect(envelope.run.sessionID == "session-1")
        #expect(envelope.run.promotedPaneID == "w1:p2")
        #expect(envelope.run.status.isTerminal)
        #expect(!HeadlessAgentRunStatus.running.isTerminal)
    }

    @Test("Decodes the act mode from a run envelope")
    func decodesActMode() throws {
        let data = Data(#"""
        {
          "ok": true,
          "run": {
            "id": "run-1",
            "status": "completed",
            "mode": "act",
            "prompt": "Open the browser",
            "response": "Opened.",
            "error": null,
            "createdAt": "2026-08-25T12:00:00Z",
            "startedAt": "2026-08-25T12:00:01Z",
            "finishedAt": "2026-08-25T12:00:02Z",
            "sessionId": "session-1",
            "sessionFile": "/private/session.jsonl",
            "costUSD": 0.012,
            "promotedWorkspaceId": null,
            "promotedPaneId": null
          }
        }
        """#.utf8)

        let envelope = try JSONDecoder().decode(HeadlessAgentRunEnvelope.self, from: data)

        #expect(envelope.run.mode == .act)
    }

    @Test("Decodes legacy run envelopes without a mode")
    func decodesRunEnvelopeWithoutMode() throws {
        let data = Data(#"""
        {
          "ok": true,
          "run": {
            "id": "run-1",
            "status": "completed",
            "prompt": "What changed?",
            "response": "Nothing.",
            "error": null,
            "createdAt": "2026-08-25T12:00:00Z",
            "startedAt": "2026-08-25T12:00:01Z",
            "finishedAt": "2026-08-25T12:00:02Z",
            "sessionId": "session-1",
            "sessionFile": "/private/session.jsonl",
            "costUSD": 0.012,
            "promotedWorkspaceId": null,
            "promotedPaneId": null
          }
        }
        """#.utf8)

        let envelope = try JSONDecoder().decode(HeadlessAgentRunEnvelope.self, from: data)

        #expect(envelope.run.mode == nil)
    }

    @Test("Encodes the start request mode")
    func encodesStartRequestMode() throws {
        let data = try JSONEncoder().encode(
            HeadlessAgentStartRequest(prompt: "hello", mode: .act)
        )
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])

        #expect(object["mode"] == "act")
        #expect(object["prompt"] == "hello")
    }

    @Test("Default start request omits ask mode for compatibility")
    func defaultStartRequestOmitsMode() throws {
        let data = try JSONEncoder().encode(HeadlessAgentStartRequest(prompt: "hello"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])

        #expect(object["prompt"] == "hello")
        #expect(object["mode"] == nil)
    }
}
