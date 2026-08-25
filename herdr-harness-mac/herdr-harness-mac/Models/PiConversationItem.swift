import Foundation

enum PiConversationItem: Identifiable, Equatable, Sendable {
    case assistant(PiAssistantBlock)
    case thinking(PiThinkingBlock)
    case tool(PiToolInvocation)
    case notice(PiConversationNotice)

    var id: String {
        switch self {
        case let .assistant(value): value.id
        case let .thinking(value): value.id
        case let .tool(value): value.id
        case let .notice(value): value.id
        }
    }

    var diffingTextLength: Int {
        switch self {
        case let .assistant(value): value.text.count
        case let .thinking(value): value.text.count
        case .tool, .notice: 0
        }
    }
}
