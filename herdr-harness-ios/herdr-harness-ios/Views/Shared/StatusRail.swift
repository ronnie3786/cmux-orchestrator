import SwiftUI

struct StatusRail: View {
    let status: AgentStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glow = 0.35

    var body: some View {
        Capsule()
            .fill(status.color)
            .frame(width: 4)
            .shadow(color: status.color.opacity(glow), radius: status == .working ? 8 : 3)
            .task(id: status) {
                glow = 0.35
                guard status == .working, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                    glow = 0.95
                }
            }
    }
}
