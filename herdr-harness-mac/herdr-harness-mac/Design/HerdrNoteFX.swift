import SwiftUI

struct HerdrBlurFade: ViewModifier {
    let blur: CGFloat
    let opacity: Double
    let offsetY: CGFloat

    func body(content: Content) -> some View {
        content.blur(radius: blur).opacity(opacity).offset(y: offsetY)
    }
}

enum HerdrNoteReveal {
    static func transition(_ reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .modifier(
                active: HerdrBlurFade(blur: 10, opacity: 0, offsetY: 10),
                identity: HerdrBlurFade(blur: 0, opacity: 1, offsetY: 0)
            ),
            removal: .modifier(
                active: HerdrBlurFade(blur: 8, opacity: 0, offsetY: -6),
                identity: HerdrBlurFade(blur: 0, opacity: 1, offsetY: 0)
            )
        )
    }
}

struct HerdrNoteShimmerOverlay: View {
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            if reduceMotion {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(color.opacity(0.35), lineWidth: 2)
            } else {
                LinearGradient(colors: [.clear, .white.opacity(0.5), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 140)
                    .rotationEffect(.degrees(18))
                    .offset(x: isAnimating ? 420 : -420)
                    .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: isAnimating)
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(color, lineWidth: 2)
                    .opacity(isAnimating ? 0.9 : 0.35)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: isAnimating)
            }
        }
        .clipShape(.rect(cornerRadius: 12))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { if !reduceMotion { isAnimating = true } }
    }
}

struct HerdrSparkleBurstView: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    var body: some View {
        if !reduceMotion {
            ZStack {
                ForEach(0..<10, id: \.self) { index in
                    let angle = Double(index) * 36 * .pi / 180
                    let radius = 26 + CGFloat(index % 3) * 4
                    if isAnimating {
                        Image(systemName: "sparkle")
                            .herdrFont(size: 8 + CGFloat(index % 4) * 2, weight: .bold, relativeTo: .caption)
                            .foregroundStyle(index.isMultiple(of: 2) ? color : .white)
                            .shadow(color: color.opacity(0.6), radius: 1)
                            .transition(
                                .asymmetric(
                                    insertion: .modifier(
                                        active: HerdrSparkleParticle(scale: 0.2, opacity: 0, x: 0, y: 0),
                                        identity: HerdrSparkleParticle(
                                            scale: 1,
                                            opacity: 1,
                                            x: CGFloat(cos(angle)) * radius,
                                            y: CGFloat(sin(angle)) * radius
                                        )
                                    ),
                                    removal: .modifier(
                                        active: HerdrSparkleParticle(
                                            scale: 0.6,
                                            opacity: 0,
                                            x: CGFloat(cos(angle)) * radius,
                                            y: CGFloat(sin(angle)) * radius
                                        ),
                                        identity: HerdrSparkleParticle(
                                            scale: 1,
                                            opacity: 1,
                                            x: CGFloat(cos(angle)) * radius,
                                            y: CGFloat(sin(angle)) * radius
                                        )
                                    )
                                )
                            )
                            .animation(
                                .easeOut(duration: 0.7).delay(Double(index) / 10 * 0.12),
                                value: isAnimating
                            )
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                isAnimating = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(850))
                    guard !Task.isCancelled else { return }
                    isAnimating = false
                }
            }
        }
    }
}

private struct HerdrSparkleParticle: ViewModifier {
    let scale: CGFloat
    let opacity: Double
    let x: CGFloat
    let y: CGFloat

    func body(content: Content) -> some View {
        content.scaleEffect(scale).opacity(opacity).offset(x: x, y: y)
    }
}
