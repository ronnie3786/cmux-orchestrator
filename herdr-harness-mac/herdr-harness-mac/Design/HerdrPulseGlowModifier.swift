import SwiftUI

/// Motion policy for "something under here is actively working".
///
/// Pure so the reduce-motion and rest/peak decisions are unit-testable without
/// a view, the way `PiChatMotion` is.
enum HerdrPulseGlow {
    /// Matches `StatusRail`'s working breath so the sidebar and the pane cards
    /// pulse at the same rate.
    static let period = 1.15
    static let restOpacity = 0.32
    static let peakOpacity = 0.85

    /// `nil` while resting so a settled row is not left holding a live
    /// `repeatForever` animation. With an unconditional repeating animation,
    /// flipping the driver *off* hands SwiftUI another infinite animation toward
    /// a constant and keeps the layer — and the display link — alive for a row
    /// that looks static. One orb can afford that; a column of rows cannot.
    static func animation(isPulsing: Bool, reduceMotion: Bool) -> Animation? {
        guard isPulsing, !reduceMotion else { return nil }
        return .easeInOut(duration: period).repeatForever(autoreverses: true)
    }

    static func opacity(isActive: Bool, isPulsing: Bool, reduceMotion: Bool) -> Double {
        guard isActive else { return 0 }
        if reduceMotion { return restOpacity }
        return isPulsing ? peakOpacity : restOpacity
    }
}

private struct HerdrPulseGlowModifier: ViewModifier {
    let color: Color
    let isActive: Bool
    let diameter: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .background {
                // A radial gradient whose only animating property is `opacity`
                // rasterizes once and alpha-composites on the render server.
                // `StatusRail` animates `.shadow(color:)`, which re-rasterizes and
                // re-blurs the glyph every frame — fine for two cards, not for a
                // scrolling column.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [color, color.opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: diameter / 2
                        )
                    )
                    .frame(width: diameter, height: diameter)
                    .opacity(
                        HerdrPulseGlow.opacity(
                            isActive: isActive,
                            isPulsing: isPulsing,
                            reduceMotion: reduceMotion
                        )
                    )
                    .animation(
                        HerdrPulseGlow.animation(isPulsing: isPulsing, reduceMotion: reduceMotion),
                        value: isPulsing
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onChange(of: isActive, initial: true) { _, _ in updatePulse() }
            .onChange(of: reduceMotion) { _, _ in updatePulse() }
    }

    private func updatePulse() { isPulsing = isActive && !reduceMotion }
}

extension View {
    /// A slow amber breath behind a status glyph, for rows whose children are
    /// actively working. Reduce Motion keeps the halo at rest instead of
    /// removing it, so the signal survives without the movement.
    func herdrPulseGlow(
        _ color: Color = HerdrTheme.working,
        isActive: Bool,
        diameter: CGFloat
    ) -> some View {
        modifier(HerdrPulseGlowModifier(color: color, isActive: isActive, diameter: diameter))
    }
}
