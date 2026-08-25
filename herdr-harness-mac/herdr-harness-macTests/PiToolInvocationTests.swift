import Testing
@testable import herdr_harness_mac

@Suite("Pi tool invocation display payloads")
struct PiToolInvocationTests {
    @Test("Large tool payloads are precomputed and truncated at a UTF-8 boundary")
    func truncatesLargePayloads() {
        let payload = String(repeating: "é", count: 40_000)
        let invocation = PiToolInvocation(
            id: "tool:large",
            callID: "large",
            name: "large",
            arguments: .string(payload),
            result: .string(payload),
            status: .succeeded,
            startedAt: nil,
            finishedAt: nil
        )
        let suffix = "\n… (truncated, \(payload.utf8.count / 1_024) KB total)"

        #expect(invocation.argumentsDisplayString?.contains("truncated") == true)
        #expect(invocation.resultDisplayString?.contains("truncated") == true)
        #expect((invocation.argumentsDisplayString?.utf8.count ?? .max) <= 65_536 + suffix.utf8.count)
        #expect((invocation.resultDisplayString?.utf8.count ?? .max) <= 65_536 + suffix.utf8.count)
    }

    @Test("Small tool payloads retain their display strings")
    func retainsSmallPayloads() {
        let arguments: PiJSONValue = .object(["path": .string("Sources/App.swift")])
        let result: PiJSONValue = .string("done")
        let invocation = PiToolInvocation(
            id: "tool:small",
            callID: "small",
            name: "read",
            arguments: arguments,
            result: result,
            status: .succeeded,
            startedAt: nil,
            finishedAt: nil
        )

        #expect(invocation.argumentsDisplayString == arguments.displayString)
        #expect(invocation.resultDisplayString == result.displayString)
        #expect(invocation.argumentsDisplayString?.contains("truncated") == false)
        #expect(invocation.resultDisplayString?.contains("truncated") == false)
    }
}
