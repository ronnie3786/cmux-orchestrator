import SwiftUI

/// A session avatar and its persistent speech bubble share one compact row.
struct HerdrHudSessionBubbleLabel: View {
    let chip: HerdrHudSessionChips.Chip

    var body: some View {
        HStack(spacing: 7) {
            VStack(alignment: .leading, spacing: 2) {
                Text(chip.title)
                    .herdrFont(.caption, weight: .semibold)
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Label(chip.statusLabel, systemImage: chip.isMuted ? "bell.slash.fill" : chip.statusSymbol)
                    .herdrFont(.caption2)
                    .foregroundStyle(chip.status.color)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(HerdrTheme.elevated, in: .rect(cornerRadius: 10))
            .overlay(alignment: .trailing) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(HerdrTheme.elevated)
                    .frame(width: 7, height: 7)
                    .rotationEffect(.degrees(45))
                    .offset(x: 3)
            }

            Text(chip.emoji)
                .font(.system(size: 20))
                .frame(width: 36, height: 36)
                .background(HerdrTheme.graphite, in: .circle)
                .overlay {
                    Circle().strokeBorder(chip.status.color.opacity(0.75), lineWidth: 1.5)
                }
                .shadow(color: chip.status == .working ? chip.status.color.opacity(0.3) : .clear, radius: 4)
                .accessibilityHidden(true)
        }
        .frame(width: HerdrHudPlacement.chipWidth, height: HerdrHudPlacement.chipHeight)
        .contentShape(.rect)
    }
}
