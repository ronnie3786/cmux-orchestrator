import Foundation
import Testing
@testable import herdr_harness_ios

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
            "prompt": "Restart the stuck worker",
            "response": "Restarted it.",
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

    @Test("Decodes model routing")
    func decodesModelRouting() throws {
        let data = Data(#"""
        {
          "ok": true,
          "run": {
            "id": "run-routed",
            "status": "completed",
            "mode": "act",
            "prompt": "Tidy the branch",
            "response": "Tidied.",
            "error": null,
            "createdAt": "2026-08-25T12:00:00Z",
            "model": "openai-codex/gpt-5.6-luna",
            "thinkingLevel": "max"
          }
        }
        """#.utf8)

        let envelope = try JSONDecoder().decode(HeadlessAgentRunEnvelope.self, from: data)

        #expect(envelope.run.mode == .act)
        #expect(envelope.run.model == "openai-codex/gpt-5.6-luna")
        #expect(envelope.run.thinkingLevel == "max")
    }

    @Test("Decodes legacy run envelopes without model routing, steps or a mode")
    func decodesLegacyRunEnvelope() throws {
        let data = Data(#"""
        {
          "ok": true,
          "run": {
            "id": "run-legacy",
            "status": "completed",
            "prompt": "What changed?",
            "response": "Nothing.",
            "error": null,
            "createdAt": "2026-08-25T12:00:00Z"
          }
        }
        """#.utf8)

        let envelope = try JSONDecoder().decode(HeadlessAgentRunEnvelope.self, from: data)

        #expect(envelope.run.mode == nil)
        #expect(envelope.run.model == nil)
        #expect(envelope.run.thinkingLevel == nil)
        #expect(envelope.run.attachments == nil)
        #expect(envelope.run.steps == nil)
        #expect(envelope.run.stepsTruncated == nil)
        #expect(envelope.run.threadRootRunId == nil)
    }

    @Test("Decodes tool steps and the truncation flag")
    func decodesSteps() throws {
        let data = Data(#"""
        {
          "ok": true,
          "run": {
            "id": "run-steps",
            "status": "running",
            "mode": "act",
            "prompt": "Check the disk",
            "response": null,
            "error": null,
            "createdAt": "2026-08-25T12:00:00Z",
            "stepsTruncated": true,
            "steps": [
              {
                "toolCallId": "call-1",
                "toolName": "bash",
                "argsPreview": "{\"command\":\"df -h\"}",
                "resultPreview": "94% used",
                "isError": true,
                "startedAt": "2026-08-25T12:00:01Z",
                "finishedAt": "2026-08-25T12:00:02Z"
              },
              {
                "toolCallId": "call-2",
                "toolName": "read",
                "argsPreview": "/etc/hosts"
              }
            ]
          }
        }
        """#.utf8)

        let envelope = try JSONDecoder().decode(HeadlessAgentRunEnvelope.self, from: data)
        let steps = try #require(envelope.run.steps)

        #expect(envelope.run.stepsTruncated == true)
        #expect(steps.count == 2)
        #expect(steps[0].toolName == "bash")
        #expect(steps[0].isError == true)
        #expect(steps[1].finishedAt == nil)
        #expect(steps[1].isError == nil)
    }

    /// The agent sheet is the Do path and does not pass a mode. The harness
    /// reads a missing `mode` as "ask", so an unset default would silently
    /// downgrade every run the sheet starts.
    @Test("A start request is a Do run unless the caller says otherwise")
    func startRequestDefaultsToActMode() throws {
        let data = try JSONEncoder().encode(
            HeadlessAgentStartRequest(prompt: "ship it", model: nil, thinkingLevel: "max")
        )
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["mode"] as? String == "act")
        #expect(object["prompt"] as? String == "ship it")
        #expect(object["thinkingLevel"] as? String == "max")
        #expect(object["model"] == nil)
    }

    /// The Pi session summary reads a transcript it does not trust, so it must
    /// never get write tools. Omitting `mode` is how the harness is told "ask",
    /// matching the Mac's encoder rather than inventing a second spelling.
    @Test("An ask run omits the mode key entirely")
    func startRequestOmitsModeForAskRuns() throws {
        let data = try JSONEncoder().encode(
            HeadlessAgentStartRequest(
                prompt: "summarize it",
                mode: .ask,
                model: nil,
                thinkingLevel: nil
            )
        )
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["mode"] == nil)
        #expect(object["prompt"] as? String == "summarize it")
    }

    @Test("A start request carries an explicit model when one is resolved")
    func startRequestEncodesResolvedModel() throws {
        let data = try JSONEncoder().encode(
            HeadlessAgentStartRequest(
                prompt: "ship it",
                model: "openai-codex/gpt-5.6-luna",
                thinkingLevel: nil
            )
        )
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["model"] as? String == "openai-codex/gpt-5.6-luna")
        #expect(object["thinkingLevel"] == nil)
    }

    @Test("Promotion sends only the target workspace id")
    func promotionRequestSendsOnlyTheWorkspaceID() throws {
        let targeted = try JSONEncoder().encode(HeadlessAgentPromotionRequest(workspaceID: "w1"))
        let targetedObject = try #require(
            try JSONSerialization.jsonObject(with: targeted) as? [String: Any]
        )
        #expect(targetedObject["workspaceId"] as? String == "w1")
        #expect(targetedObject.count == 1)

        let quickChats = try JSONEncoder().encode(HeadlessAgentPromotionRequest(workspaceID: nil))
        let quickChatsObject = try #require(
            try JSONSerialization.jsonObject(with: quickChats) as? [String: Any]
        )
        #expect(quickChatsObject["workspaceId"] == nil)
    }
}
