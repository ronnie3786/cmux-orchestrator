import SwiftUI

struct AgentStatusBadge: View {
    let status: AgentStatus
    var compact = false

    var body: some View {
        Label(compact ? status.compactTitle : status.title, systemImage: status.symbol)
            .font(.caption.bold())
            .foregroundStyle(status.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(status.color.opacity(0.11), in: Capsule())
            .overlay {
                Capsule().strokeBorder(status.color.opacity(0.28), lineWidth: 1)
            }
            .accessibilityLabel("Agent status: \(status.title)")
    }
}
