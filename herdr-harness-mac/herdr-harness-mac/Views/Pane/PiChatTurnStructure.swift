struct PiChatTurnStructure: Equatable {
    let itemsRevision: Int
    let showsStartingIndicator: Bool

    init(turn: PiConversationTurn) {
        itemsRevision = turn.itemsRevision
        showsStartingIndicator = turn.isActive && turn.items.isEmpty
    }
}
