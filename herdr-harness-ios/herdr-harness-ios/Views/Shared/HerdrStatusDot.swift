import SwiftUI

struct HerdrStatusDot: View {
    let status: AgentStatus

    var body: some View {
        Text(status.terminalGlyph)
            .font(.body.monospaced().bold())
            .foregroundStyle(status.color)
            .accessibilityLabel(status.title)
    }
}
