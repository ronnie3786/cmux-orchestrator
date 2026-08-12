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
            .background(HerdrTheme.graphite)
            .clipShape(.rect(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(HerdrTheme.surface.opacity(0.85), lineWidth: 1)
            }
    }
}
