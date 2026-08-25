import Foundation

struct PiToolInvocation: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case waiting
        case running
        case succeeded
        case failed
    }

    let id: String
    let callID: String
    let argumentsDisplayString: String?
    let resultDisplayString: String?
    var name: String
    var arguments: PiJSONValue?
    var result: PiJSONValue?
    var status: Status
    var startedAt: Date?
    var finishedAt: Date?

    init(
        id: String,
        callID: String,
        name: String,
        arguments: PiJSONValue?,
        result: PiJSONValue?,
        status: Status,
        startedAt: Date?,
        finishedAt: Date?
    ) {
        self.id = id
        self.callID = callID
        let isTerminal = status == .succeeded || status == .failed
        self.argumentsDisplayString = isTerminal ? Self.displayString(for: arguments) : arguments?.stringValue
        self.resultDisplayString = isTerminal ? Self.displayString(for: result) : result?.stringValue
        self.name = name
        self.arguments = arguments
        self.result = result
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    private static func displayString(for value: PiJSONValue?) -> String? {
        guard let value else { return nil }
        let display = value.displayString
        let byteCount = display.utf8.count
        guard byteCount > 65_536 else { return display }

        var prefixEnd = display.startIndex
        var prefixByteCount = 0
        for index in display.indices {
            let nextIndex = display.index(after: index)
            let characterByteCount = display[index..<nextIndex].utf8.count
            guard prefixByteCount + characterByteCount <= 65_536 else { break }
            prefixByteCount += characterByteCount
            prefixEnd = nextIndex
        }
        let totalKB = byteCount / 1_024
        return String(display[..<prefixEnd]) + "\n… (truncated, \(totalKB) KB total)"
    }
}
