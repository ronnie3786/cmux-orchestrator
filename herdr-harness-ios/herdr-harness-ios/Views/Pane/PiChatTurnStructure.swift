struct PiChatTurnStructure: Equatable {
    let userID: String?
    let itemIDs: [String]
    let showsStartingIndicator: Bool

    init(turn: PiConversationTurn) {
        userID = turn.user?.id
        itemIDs = turn.items.map(\.id)
        showsStartingIndicator = turn.isActive && turn.items.isEmpty
    }
}
