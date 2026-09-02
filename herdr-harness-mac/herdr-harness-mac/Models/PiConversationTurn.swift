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

extension BidirectionalCollection where Element == PiConversationTurn {
    /// The newest finished assistant answer — what response audio reads.
    ///
    /// Shared by the live chat store and by the HUD chip, which projects a
    /// fetched snapshot through the same reducer rather than following a
    /// stream, so both surfaces speak the same text.
    var latestCompletedAssistantText: String? {
        for turn in reversed() {
            for item in turn.items.reversed() {
                guard case let .assistant(block) = item,
                      block.status == .complete
                else { continue }
                let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        return nil
    }
}
