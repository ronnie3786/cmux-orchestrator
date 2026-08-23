import Testing
@testable import herdr_harness_mac

@Suite("Herdr SSE parser")
struct HerdrSSEParserTests {
    @Test("A malformed record cannot poison the next record")
    func malformedRecordIsDiscardedWhenNextEventStarts() {
        var parser = HerdrSSEParser()
        #expect(parser.consume(line: "event: snapshot.updated") == nil)
        #expect(parser.consume(line: "data: {") == nil)
        #expect(parser.consume(line: "event: snapshot.updated") == nil)
        let event = parser.consume(line: "data: {\"ok\":true}")

        #expect(event?.event == "snapshot.updated")
        #expect(event?.data == .object(["ok": .bool(true)]))
    }

    @Test("Ignored global events remain lightweight while preserving IDs")
    func ignoredEventsSkipPayloadDecoding() {
        var parser = HerdrSSEParser()
        for id in 1...100 {
            #expect(parser.consume(line: "id: \(id)") == nil)
            #expect(parser.consume(line: "event: pi.message_update") == nil)
            let event = parser.consume(line: "data: {not valid json")
            #expect(event == HerdrEvent(id: id, event: "pi.message_update", data: .null))
        }
    }

    @Test("Decoded fleet events still retain their payload")
    func snapshotEventsDecodePayload() {
        var parser = HerdrSSEParser()
        #expect(parser.consume(line: "id: 42") == nil)
        #expect(parser.consume(line: "event: snapshot.updated") == nil)
        let event = parser.consume(line: "data: {\"revision\":7}")

        #expect(event?.id == 42)
        #expect(event?.data == .object(["revision": .number(7)]))
    }

    @Test("Broker envelopes are unwrapped")
    func brokerEnvelopeIsUnwrapped() {
        var parser = HerdrSSEParser()
        #expect(parser.consume(line: "id: 7") == nil)
        #expect(parser.consume(line: "event: push.delivery") == nil)
        let event = parser.consume(line: "data: {\"id\":7,\"event\":\"push.delivery\",\"data\":{\"sent\":1,\"alertId\":\"a1\"},\"generatedAt\":\"x\"}")

        #expect(event?.id == 7)
        #expect(event?.event == "push.delivery")
        #expect(event?.data == .object(["sent": .number(1), "alertId": .string("a1")]))
    }

    @Test("Hand-written records retain their complete payload")
    func handWrittenRecordKeepsPayload() {
        var parser = HerdrSSEParser()
        #expect(parser.consume(line: "event: stream.reset") == nil)
        let event = parser.consume(line: "data: {\"event\":\"stream.reset\",\"reason\":\"backend_restarted\",\"resumeAfter\":0,\"generatedAt\":\"x\"}")

        #expect(event?.data == .object([
            "event": .string("stream.reset"),
            "reason": .string("backend_restarted"),
            "resumeAfter": .number(0),
            "generatedAt": .string("x"),
        ]))
    }

    @Test("Message records take their name from broker envelopes")
    func messageRecordTakesNameFromEnvelope() {
        var parser = HerdrSSEParser()
        let event = parser.consume(line: "data: {\"id\":3,\"event\":\"alert.created\",\"data\":{\"x\":1}}")

        #expect(event?.event == "alert.created")
        #expect(event?.id == 3)
        #expect(event?.data == .object(["x": .number(1)]))
    }

    @Test("The line cap clears an incomplete record")
    func lineCapClearsRecord() {
        var parser = HerdrSSEParser()
        #expect(parser.consume(line: "event: snapshot.updated") == nil)
        for _ in 0...64 {
            #expect(parser.consume(line: "data: {") == nil)
        }
        #expect(parser.consume(line: "event: snapshot.updated") == nil)
        let event = parser.consume(line: "data: {\"ok\":true}")
        #expect(event?.data == .object(["ok": .bool(true)]))
    }

    @Test("The byte cap clears an incomplete record")
    func byteCapClearsRecord() {
        var parser = HerdrSSEParser()
        #expect(parser.consume(line: "event: snapshot.updated") == nil)
        #expect(parser.consume(line: "data: \(String(repeating: "x", count: 4 * 1024 * 1024))") == nil)
        #expect(parser.consume(line: "event: snapshot.updated") == nil)
        let event = parser.consume(line: "data: {\"ok\":true}")

        #expect(event?.data == .object(["ok": .bool(true)]))
    }
}
