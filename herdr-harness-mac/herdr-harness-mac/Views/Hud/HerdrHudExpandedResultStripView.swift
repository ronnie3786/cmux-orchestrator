import SwiftUI

/// Keeps finished outputs visible when a HUD run auto-opens the full card.
/// The same constellation used beside collapsed sessions docks to a small
/// agent core here, preserving one visual language across both HUD states.
struct HerdrHudExpandedResultStripView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Bindable var model: HerdrAppModel

    private var artifacts: [AgentResultArtifact] {
        model.unopenedResultArtifacts
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text("AGENT OUTPUT")
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .foregroundStyle(HerdrTheme.accent)
                Text("\(artifacts.count) UNVIEWED")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(HerdrTheme.mist.opacity(0.72))
            }

            Spacer(minLength: 8)

            HerdrHudResultArtifactRailView(model: model, artifacts: artifacts)
            agentCore
        }
        .padding(.horizontal, HerdrTheme.cardPadding)
        .frame(height: 46)
        .background {
            LinearGradient(
                colors: [
                    HerdrTheme.ink.opacity(0.76),
                    HerdrTheme.graphite.opacity(0.96),
                    HerdrTheme.mauve.opacity(0.055),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.clear, HerdrTheme.accent.opacity(0.22), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
        }
        .transition(
            reduceMotion
                ? .opacity
                : .move(edge: .top).combined(with: .opacity)
        )
        .accessibilityIdentifier("hud-expanded-result-strip")
    }

    private var agentCore: some View {
        ZStack {
            Circle()
                .fill(HerdrTheme.ink)
                .shadow(color: HerdrTheme.accent.opacity(0.42), radius: 6)
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [HerdrTheme.mauve, HerdrTheme.accent],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            Image(systemName: "sparkles")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(HerdrTheme.accent)
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}
