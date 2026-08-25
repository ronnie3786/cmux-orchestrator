import Foundation

struct PiConversationTurn: Identifiable, Equatable, Sendable {
    let id: String
    var user: PiUserMessage?
    var items: [PiConversationItem]
    var itemsRevision: Int = 0
    var startedAt: Date?
    var isActive: Bool

    var hasVisibleContent: Bool {
        user != nil || !items.isEmpty
    }
}
