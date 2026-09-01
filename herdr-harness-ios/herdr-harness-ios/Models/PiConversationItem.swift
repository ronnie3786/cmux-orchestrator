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

    /// Sub-process activity, thinking and tool/command invocations, that
    /// `PiConversationTurnView` folds into a collapsed "Working…" group so it
    /// does not sit between Pi's actual output messages. Assistant prose and
    /// notices (including the failure notices Pi emits) always stay visible.
    var isWorking: Bool {
        switch self {
        case .thinking, .tool: true
        case .assistant, .notice: false
        }
    }
}
