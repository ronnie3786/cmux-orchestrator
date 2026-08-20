import Foundation

struct PiThinkingBlock: Identifiable, Equatable, Sendable {
    let id: String
    var text: String
    var isStreaming: Bool
    var isRedacted: Bool
    var startedAt: Date?
}
