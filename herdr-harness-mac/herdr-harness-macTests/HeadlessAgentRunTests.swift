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
}
