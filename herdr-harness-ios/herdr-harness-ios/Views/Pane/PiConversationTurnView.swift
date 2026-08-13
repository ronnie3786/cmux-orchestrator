import SwiftUI

struct PiConversationTurnView: View {
    let turn: PiConversationTurn

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PiTurnActivityRail(turn: turn)
                .frame(minHeight: 54)

            VStack(alignment: .leading, spacing: 13) {
                if let user = turn.user {
                    PiUserMessageView(message: user)
                }

                ForEach(turn.items) { item in
                    PiConversationItemView(item: item)
                }

                if turn.isActive, turn.items.isEmpty {
                    HStack(spacing: 9) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(HerdrTheme.mauve)
                        Text("Pi is starting…")
                            .font(.callout)
                            .foregroundStyle(HerdrTheme.mist)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("pi-turn-\(turn.id)")
    }
}
