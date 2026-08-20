import SwiftUI

struct ConnectionPill: View {
    let state: ConnectionState

    var body: some View {
        Label(state.title, systemImage: state.symbol)
            .herdrFont(.caption, monospaced: true, weight: .bold)
            .foregroundStyle(state.color)
            .padding(.vertical, 8)
            .accessibilityLabel("Server \(state.title)")
    }
}
