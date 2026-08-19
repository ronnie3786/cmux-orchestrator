import SwiftUI

struct HerdrVoiceWaveform: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let samples: [CGFloat]
    let isRecording: Bool
    let showsContainer: Bool

    init(samples: [CGFloat], isRecording: Bool, showsContainer: Bool = true) {
        self.samples = samples
        self.isRecording = isRecording
        self.showsContainer = showsContainer
    }

    var body: some View {
        GeometryReader { geometry in
            let spacing = 3.0
            let barCount = CGFloat(max(samples.count, 1))
            let totalSpacing = spacing * CGFloat(max(samples.count - 1, 0))
            let barWidth = max(2, (geometry.size.width - totalSpacing) / barCount)

            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor(index: index))
                        .frame(
                            width: barWidth,
                            height: max(4, geometry.size.height * min(max(sample, 0.08), 1))
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 52)
        .padding(.horizontal, showsContainer ? 12 : 0)
        .padding(.vertical, showsContainer ? 8 : 0)
        .background(showsContainer ? HerdrTheme.elevated : .clear)
        .overlay {
            if showsContainer {
                RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                    .strokeBorder(HerdrTheme.surface, lineWidth: 1)
            }
        }
        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
        .animation(reduceMotion ? nil : .linear(duration: 0.08), value: samples)
        .accessibilityHidden(true)
    }

    private func barColor(index: Int) -> Color {
        let baseColor = isRecording ? HerdrTheme.alert : HerdrTheme.accent
        guard samples.count > 1 else { return baseColor.opacity(0.62) }
        let recency = Double(index) / Double(samples.count - 1)
        return baseColor.opacity(isRecording ? 0.30 + recency * 0.65 : 0.45)
    }
}
