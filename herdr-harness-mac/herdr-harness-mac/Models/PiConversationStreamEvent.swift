import Foundation

enum PiConversationStreamEvent: Equatable, Sendable {
    case activity
    case envelope(PiConversationEnvelope)
}
