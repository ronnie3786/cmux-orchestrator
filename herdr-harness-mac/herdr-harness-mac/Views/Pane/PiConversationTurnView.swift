import SwiftUI

struct PiConversationTurnView: View {
    let turn: PiConversationTurn
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let structure = PiChatTurnStructure(turn: turn)

        HStack(alignment: .top, spacing: 12) {
            PiTurnActivityRail(turn: turn)
                .frame(minHeight: 54)

            VStack(alignment: .leading, spacing: 13) {
                if let user = turn.user {
                    PiUserMessageView(message: user)
                        .transition(PiChatMotion.itemTransition(reduceMotion: reduceMotion))
                }

                ForEach(turn.items) { item in
                    PiConversationItemView(item: item)
                        .transition(PiChatMotion.itemTransition(reduceMotion: reduceMotion))
                }

                if turn.isActive, turn.items.isEmpty {
                    HStack(spacing: 9) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(HerdrTheme.mauve)
                        Text("Pi is starting…")
                            .herdrFont(.callout)
                            .foregroundStyle(HerdrTheme.mist)
                    }
                    .transition(PiChatMotion.itemTransition(reduceMotion: reduceMotion))
                    .accessibilityIdentifier("pi-turn-starting-\(turn.id)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(
                PiChatMotion.structuralAnimation(reduceMotion: reduceMotion),
                value: structure
            )
        }
        .accessibilityIdentifier("pi-turn-\(turn.id)")
    }
}
