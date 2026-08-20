import Foundation

/// Finds the last thing the operator actually typed to Pi in this pane, so
/// UI that bounces between panes can remind them what they asked.
enum PiLastPrompt {
    /// Scans `turns` from the end and returns the first turn's `user`
    /// message it finds. Turns with no user message (orphan tool/assistant
    /// turns) are skipped. An in-flight turn whose only content so far is
    /// the echoed prompt itself still has `user` set, so it is returned
    /// just like any completed turn.
    static func lastUserMessage(in turns: [PiConversationTurn]) -> PiUserMessage? {
        for turn in turns.reversed() {
            if let user = turn.user { return user }
        }
        return nil
    }
}
