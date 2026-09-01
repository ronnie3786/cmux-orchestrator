import SwiftUI

struct StatusRail: View {
    let status: AgentStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        Capsule()
            .fill(status.color)
            .frame(width: 4)
            .overlay {
                if status == .working {
                    // The blurred overlay is static. Only its composited opacity breathes.
                    Capsule()
                        .fill(status.color)
                        .blur(radius: 8)
                        .opacity(
                            HerdrPulseGlow.opacity(
                                isActive: status == .working,
                                isPulsing: isPulsing,
                                reduceMotion: reduceMotion
                            )
                        )
                        .animation(
                            HerdrPulseGlow.animation(
                                isPulsing: isPulsing,
                                reduceMotion: reduceMotion
                            ),
                            value: isPulsing
                        )
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onChange(of: status, initial: true) { _, _ in updatePulse() }
            .onChange(of: reduceMotion) { _, _ in updatePulse() }
    }

    private func updatePulse() {
        isPulsing = status == .working && !reduceMotion
    }
}
