import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Herdr HUD steps")
@MainActor
struct HerdrHudStepsTests {
    @Test("Decodes a legacy run without step fields")
    func decodesLegacyRunWithoutSteps() throws {
        let data = Data(#"""
        {
          "ok": true,
          "run": {
            "id": "run-legacy",
            "status": "completed",
            "prompt": "What changed?",
            "response": "Nothing.",
            "error": null,
            "createdAt": "2026-09-01T17:45:44.166Z"
          }
        }
        """#.utf8)

        let envelope = try JSONDecoder().decode(HeadlessAgentRunEnvelope.self, from: data)

        #expect(envelope.run.steps == nil)
        #expect(envelope.run.stepsTruncated == nil)
    }

    @Test("Decodes terminal and running tool steps")
    func decodesToolStepRecords() throws {
        let data = Data(#"""
        {
          "ok": true,
          "run": {
            "id": "run-steps",
            "status": "completed",
            "prompt": "Run a command",
            "response": "Done.",
            "error": null,
            "createdAt": "2026-09-01T17:45:44.166Z",
            "steps": [
              {
                "toolCallId": "chatcmpl-tool-a8ae3daf",
                "toolName": "bash",
                "argsPreview": "{\"command\":\"echo hello-from-herdr\"}",
                "resultPreview": "{\"content\":[{\"type\":\"text\",\"text\":\"hello-from-herdr\\n\"}]}",
                "isError": false,
                "startedAt": "2026-09-01T17:45:44.166Z",
                "finishedAt": "2026-09-01T17:45:44.196Z",
                "truncated": false
              },
              {
                "toolCallId": "chatcmpl-tool-running",
                "toolName": "bash",
                "argsPreview": "{\"command\":\"false\"}",
                "resultPreview": "",
                "isError": true,
                "startedAt": "2026-09-01T17:45:45.166Z",
                "finishedAt": null,
                "truncated": false
              }
            ],
            "stepsTruncated": false
          }
        }
        """#.utf8)

        let envelope = try JSONDecoder().decode(HeadlessAgentRunEnvelope.self, from: data)
        let steps = try #require(envelope.run.steps)
        let terminal = try #require(steps.first)
        let running = try #require(steps.last)

        #expect(terminal.toolCallId == "chatcmpl-tool-a8ae3daf")
        #expect(terminal.finishedAt == "2026-09-01T17:45:44.196Z")
        #expect(running.finishedAt == nil)
        #expect(running.isError == true)
        #expect(envelope.run.stepsTruncated == false)
    }

    @Test("Maps tool steps through the shared Pi presentation")
    func mapsToolStepsThroughSharedPresentation() {
        let source = HeadlessAgentStep(
            toolCallId: "call-1",
            toolName: "bash",
            argsPreview: "{\"command\":\"echo hello\"}",
            resultPreview: nil,
            isError: true,
            startedAt: nil,
            finishedAt: nil,
            truncated: nil
        )

        let step = HerdrHudSession.hudSteps(from: [source]).first
        let presentation = PiToolPresentation.details(forToolName: "bash")

        #expect(step?.title == presentation.title)
        #expect(step?.symbol == presentation.symbol)
        #expect(step?.detail == "echo hello")
        #expect(step?.isRunning == true)
        #expect(step?.isFailure == true)
    }

    @Test("Step detail is single line and bounded")
    func boundsStepDetail() {
        let preview = Array(repeating: "line one\nline two", count: 30).joined(separator: "\n")
        let source = HeadlessAgentStep(
            toolCallId: "call-1",
            toolName: "read",
            argsPreview: preview,
            resultPreview: nil,
            isError: nil,
            startedAt: nil,
            finishedAt: "2026-09-01T17:45:44.196Z",
            truncated: nil
        )

        let detail = HerdrHudSession.hudSteps(from: [source]).first?.detail ?? ""

        #expect(detail.count <= 120)
        #expect(!detail.contains(where: { $0.isNewline }))
    }

    @Test("Maps empty and absent step arrays to no display steps")
    func mapsEmptyAndAbsentSteps() {
        let absent: [HeadlessAgentStep]? = nil

        #expect(HerdrHudSession.hudSteps(from: []).isEmpty)
        #expect(HerdrHudSession.hudSteps(from: absent ?? []).isEmpty)
    }
}
