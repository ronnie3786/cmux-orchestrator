struct PiChatTimelineStructure: Equatable {
    let identifiers: [String]

    init(
        turns: [PiConversationTurn],
        pendingInteractions: [PiPendingInteraction],
        hasContent: Bool,
        isTruncated: Bool
    ) {
        var identifiers = turns.flatMap { turn in
            ["turn:\(turn.id)"] + turn.items.map { "item:\(turn.id):\($0.id)" }
        }
        identifiers.append(contentsOf: pendingInteractions.map { "interaction:\($0.id)" })
        identifiers.append(hasContent ? "transcript:content" : "transcript:empty")
        if isTruncated {
            identifiers.append("transcript:truncated")
        }
        self.identifiers = identifiers
    }
}
