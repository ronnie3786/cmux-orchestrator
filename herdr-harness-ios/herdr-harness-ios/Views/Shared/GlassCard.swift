import SwiftUI

struct GlassCard<Content: View>: View {
    let radius: Double
    @ViewBuilder let content: Content

    init(radius: Double = HerdrTheme.cardRadius, @ViewBuilder content: () -> Content) {
        self.radius = radius
        self.content = content()
    }

    var body: some View {
        content
            .background(.ultraThinMaterial)
            .background(HerdrTheme.graphite.opacity(0.72))
            .clipShape(.rect(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(.white.opacity(0.09), lineWidth: 1)
            }
    }
}
