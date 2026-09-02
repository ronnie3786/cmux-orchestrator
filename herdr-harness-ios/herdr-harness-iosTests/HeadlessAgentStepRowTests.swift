import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Headless agent step rows")
struct HeadlessAgentStepRowTests {
    @Test("A shell step shows the command, not the raw JSON args")
    func shellStepShowsTheCommand() {
        let rows = HeadlessAgentStepRow.rows(from: [
            step(toolName: "bash", argsPreview: #"{"command":"git status --short","cwd":"/tmp"}"#)
        ])

        #expect(rows.count == 1)
        #expect(rows[0].title == "Command")
        #expect(rows[0].symbol == "terminal")
        #expect(rows[0].detail == "git status --short")
    }

    @Test("A shell step with unparseable args falls back to the raw preview")
    func shellStepFallsBackToRawArgs() {
        let rows = HeadlessAgentStepRow.rows(from: [
            step(toolName: "bash", argsPreview: "git status --short", resultPreview: "clean")
        ])

        #expect(rows[0].detail == "git status --short")
    }

    @Test("A non-shell step prefers its args and falls back to its result")
    func nonShellStepPrefersArgsThenResult() {
        let rows = HeadlessAgentStepRow.rows(from: [
            step(toolName: "read", argsPreview: #"{"path":"/etc/hosts"}"#, resultPreview: "127.0.0.1"),
            step(toolName: "read", argsPreview: nil, resultPreview: "127.0.0.1"),
            step(toolName: "read", argsPreview: nil, resultPreview: nil)
        ])

        #expect(rows[0].title == "Read")
        // No JSON extraction outside the shell branch: the args are shown as-is.
        #expect(rows[0].detail == #"{"path":"/etc/hosts"}"#)
        #expect(rows[1].detail == "127.0.0.1")
        #expect(rows[2].detail.isEmpty)
    }

    @Test("A preview is squashed to one line")
    func previewIsSquashedToOneLine() {
        let rows = HeadlessAgentStepRow.rows(from: [
            step(toolName: "read", argsPreview: "first\n  second\t\tthird\n")
        ])

        #expect(rows[0].detail == "first second third")
    }

    @Test("An overlong preview is ellipsised at exactly 120 characters")
    func overlongPreviewIsEllipsised() {
        let long = String(repeating: "a", count: 200)
        let rows = HeadlessAgentStepRow.rows(from: [step(toolName: "read", argsPreview: long)])

        #expect(rows[0].detail.count == 120)
        #expect(rows[0].detail.hasSuffix("…"))
        #expect(rows[0].detail.dropLast() == String(repeating: "a", count: 119))

        let exact = String(repeating: "b", count: 120)
        let untouched = HeadlessAgentStepRow.rows(from: [step(toolName: "read", argsPreview: exact)])
        #expect(untouched[0].detail == exact)
    }

    @Test("An unfinished step is running and a failed step is a failure")
    func runningAndFailureFlags() {
        let rows = HeadlessAgentStepRow.rows(from: [
            step(toolName: "bash", isError: true, finishedAt: "2026-08-25T12:00:02Z"),
            step(toolName: "bash", isError: nil, finishedAt: nil)
        ])

        #expect(rows[0].isFailure)
        #expect(!rows[0].isRunning)
        #expect(!rows[1].isFailure)
        #expect(rows[1].isRunning)
    }

    @Test("Steps without a tool call id still get stable unique ids")
    func stepsWithoutToolCallIDsGetUniqueIDs() {
        let rows = HeadlessAgentStepRow.rows(from: [
            step(toolCallId: nil, toolName: "bash"),
            step(toolCallId: "", toolName: "read"),
            step(toolCallId: "call-3", toolName: "read")
        ])

        #expect(rows.map(\.id) == ["agent-step-0", "agent-step-1", "call-3"])
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    @Test("A step without a tool name falls back to the generic tool chrome")
    func missingToolNameFallsBack() {
        let rows = HeadlessAgentStepRow.rows(from: [
            step(toolCallId: "call-1", toolName: nil),
            step(toolCallId: "call-2", toolName: "")
        ])

        #expect(rows.allSatisfy { $0.title == "Tool" })
        #expect(rows.allSatisfy { $0.symbol == "wrench.and.screwdriver" })
    }

    private func step(
        toolCallId: String? = "call-1",
        toolName: String?,
        argsPreview: String? = nil,
        resultPreview: String? = nil,
        isError: Bool? = nil,
        finishedAt: String? = "2026-08-25T12:00:02Z"
    ) -> HeadlessAgentStep {
        HeadlessAgentStep(
            toolCallId: toolCallId,
            toolName: toolName,
            argsPreview: argsPreview,
            resultPreview: resultPreview,
            isError: isError,
            startedAt: "2026-08-25T12:00:01Z",
            finishedAt: finishedAt,
            truncated: nil
        )
    }
}
