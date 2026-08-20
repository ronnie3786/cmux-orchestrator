import Foundation

struct PiConversationSSEParser {
    private var eventName = "message"
    private var eventID: String?
    private var dataLines: [String] = []
    private let decoder = JSONDecoder()

    mutating func consume(line: String) throws -> PiConversationStreamEvent? {
        if line.hasPrefix(":") {
            return .activity
        }
        if line.hasPrefix("event:") {
            eventName = fieldValue(in: line, prefixLength: 6)
            return nil
        }
        if line.hasPrefix("id:") {
            eventID = fieldValue(in: line, prefixLength: 3)
            return nil
        }
        if line.hasPrefix("data:") {
            dataLines.append(fieldValue(in: line, prefixLength: 5))
            return try dispatchIfComplete(force: false)
        }
        guard line.isEmpty else { return nil }
        return try dispatchIfComplete(force: true)
    }

    /// URLSession's async line sequence can omit the empty separator between
    /// SSE records on a long-lived response. Pi payloads are JSON, so dispatch
    /// as soon as the accumulated data forms a complete envelope. Keeping an
    /// incomplete payload buffered preserves standard multiline SSE support.
    private mutating func dispatchIfComplete(force: Bool) throws -> PiConversationStreamEvent? {
        guard !dataLines.isEmpty else {
            if force { resetRecord() }
            return nil
        }

        let dispatchedEventName = eventName
        let dispatchedID = eventID
        let payload = dataLines.joined(separator: "\n")

        switch dispatchedEventName {
        case "ready", "pi.ready", "heartbeat", "pi.heartbeat":
            resetRecord()
            return .activity
        case "pi.error", "pi.stream.closed":
            resetRecord()
            throw APIError.streamEnded
        default:
            guard dispatchedEventName.hasPrefix("pi.") || dispatchedEventName == "message" else {
                if force { resetRecord() }
                return nil
            }
            guard let data = payload.data(using: .utf8), !data.isEmpty else {
                if force { resetRecord() }
                return nil
            }
            do {
                let envelope = try decoder.decode(PiConversationEnvelope.self, from: data)
                resetRecord()
                return .envelope(envelope.withCursor(dispatchedID))
            } catch {
                guard force else { return nil }
                resetRecord()
                throw APIError.invalidResponse
            }
        }
    }

    private mutating func resetRecord() {
        eventName = "message"
        eventID = nil
        dataLines.removeAll(keepingCapacity: true)
    }

    private func fieldValue(in line: String, prefixLength: Int) -> String {
        var value = line.dropFirst(prefixLength)
        if value.first == " " { value = value.dropFirst() }
        return String(value)
    }
}
