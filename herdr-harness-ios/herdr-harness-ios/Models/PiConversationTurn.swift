import Foundation

struct PiConversationTurn: Identifiable, Equatable, Sendable {
    let id: String
    var user: PiUserMessage?
    var items: [PiConversationItem]
    var startedAt: Date?
    var isActive: Bool

    var hasVisibleContent: Bool {
        user != nil || !items.isEmpty
    }
}
