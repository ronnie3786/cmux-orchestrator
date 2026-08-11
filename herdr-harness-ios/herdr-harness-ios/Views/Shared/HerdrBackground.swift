import SwiftUI

struct HerdrBackground: View {
    var body: some View {
        ZStack {
            HerdrTheme.ink

            RadialGradient(
                colors: [HerdrTheme.signal.opacity(0.09), .clear],
                center: .topTrailing,
                startRadius: 8,
                endRadius: 440
            )

            LinearGradient(
                colors: [.clear, HerdrTheme.graphite.opacity(0.38), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}
