struct PiChatTurnStructure: Equatable {
    let itemsRevision: Int
    let segmentIDs: [String]
    let showsStartingIndicator: Bool

    init(turn: PiConversationTurn) {
        self.init(turn: turn, segments: PiTurnSegmentation.segments(for: turn.items))
    }

    init(turn: PiConversationTurn, segments: [PiTurnSegment]) {
        itemsRevision = turn.itemsRevision
        segmentIDs = segments.map(\.id)
        showsStartingIndicator = turn.isActive && turn.items.isEmpty
    }
}
