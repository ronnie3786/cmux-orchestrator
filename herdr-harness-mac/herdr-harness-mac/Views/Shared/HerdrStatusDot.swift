import SwiftUI

struct HerdrStatusDot: View {
    let status: AgentStatus

    var body: some View {
        Text(status.terminalGlyph)
            .herdrFont(.body, monospaced: true, weight: .bold)
            .foregroundStyle(status.color)
            .accessibilityLabel(status.title)
    }
}
