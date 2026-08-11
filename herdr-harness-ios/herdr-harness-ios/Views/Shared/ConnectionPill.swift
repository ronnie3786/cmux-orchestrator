import SwiftUI

struct ConnectionPill: View {
    let state: ConnectionState

    var body: some View {
        Label(state.title, systemImage: state.symbol)
            .font(.caption.bold())
            .foregroundStyle(state.color)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(state.color.opacity(0.10), in: Capsule())
            .overlay {
                Capsule().strokeBorder(state.color.opacity(0.24), lineWidth: 1)
            }
            .accessibilityLabel("Server \(state.title)")
    }
}
