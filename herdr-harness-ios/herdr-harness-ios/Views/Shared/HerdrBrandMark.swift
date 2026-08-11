import SwiftUI

struct HerdrBrandMark: View {
    var size = 54.0

    var body: some View {
        HStack(spacing: size * 0.09) {
            paneShape
                .foregroundStyle(HerdrTheme.accent)
            paneShape
                .foregroundStyle(HerdrTheme.mist)
                .scaleEffect(y: 0.78)
            paneShape
                .foregroundStyle(HerdrTheme.signal)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var paneShape: some View {
        RoundedRectangle(cornerRadius: size * 0.09)
            .frame(width: size * 0.22, height: size * 0.72)
    }
}
