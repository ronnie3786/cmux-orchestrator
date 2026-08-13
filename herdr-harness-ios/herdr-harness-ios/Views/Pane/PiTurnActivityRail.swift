import SwiftUI

struct PiTurnActivityRail: View {
    let turn: PiConversationTurn
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(turn.user == nil ? HerdrTheme.muted : HerdrTheme.accent)
                .frame(width: 7, height: 7)

            Rectangle()
                .fill(railGradient)
                .frame(width: 1)

            Circle()
                .fill(terminalColor)
                .frame(width: 7, height: 7)
        }
        .frame(width: 10)
        .animation(
            PiChatMotion.stateAnimation(reduceMotion: reduceMotion),
            value: visualState
        )
        .accessibilityHidden(true)
    }

    private var railGradient: LinearGradient {
        let colors: [Color]
        if turn.items.contains(where: Self.isTool) {
            colors = [HerdrTheme.accent.opacity(0.55), HerdrTheme.mauve.opacity(0.7), HerdrTheme.signal.opacity(0.62)]
        } else {
            colors = [HerdrTheme.accent.opacity(0.48), HerdrTheme.mauve.opacity(0.4), HerdrTheme.success.opacity(0.52)]
        }
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    private var terminalColor: Color {
        if turn.items.contains(where: Self.isFailed) { return HerdrTheme.alert }
        return turn.isActive ? HerdrTheme.working : HerdrTheme.success
    }

    private var visualState: String {
        let hasTool = turn.items.contains(where: Self.isTool)
        let hasFailure = turn.items.contains(where: Self.isFailed)
        return "\(turn.user?.id ?? "none"):\(hasTool):\(hasFailure):\(turn.isActive)"
    }

    private static func isTool(_ item: PiConversationItem) -> Bool {
        if case .tool = item { return true }
        return false
    }

    private static func isFailed(_ item: PiConversationItem) -> Bool {
        switch item {
        case let .assistant(block):
            if case .failed = block.status { return true }
            return false
        case let .tool(tool):
            return tool.status == .failed
        case let .notice(notice):
            return notice.tone == .error
        case .thinking:
            return false
        }
    }
}
