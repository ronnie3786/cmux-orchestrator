enum HerdrHudNotificationFilter {
    static func panes(_ panes: [HerdrPane]) -> [HerdrPane] {
        panes.filter(\.supportsPiSemanticChat)
    }

    static func alerts(_ alerts: [HerdrAlert], panes: [HerdrPane]) -> [HerdrAlert] {
        let piChatPaneIDs = Set(panes.filter(\.supportsPiSemanticChat).map(\.id))
        return alerts.filter { piChatPaneIDs.contains($0.scopedPaneID) }
    }
}
