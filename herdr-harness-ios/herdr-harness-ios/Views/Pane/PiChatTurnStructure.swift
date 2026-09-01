struct PiChatTurnStructure: Equatable {
    let userID: String?
    let itemIDs: [String]
    let segmentIDs: [String]
    let showsStartingIndicator: Bool

    init(turn: PiConversationTurn) {
        self.init(turn: turn, segments: PiTurnSegmentation.segments(for: turn.items))
    }

    init(turn: PiConversationTurn, segments: [PiTurnSegment]) {
        userID = turn.user?.id
        itemIDs = turn.items.map(\.id)
        segmentIDs = segments.map(\.id)
        showsStartingIndicator = turn.isActive && turn.items.isEmpty
    }
}
