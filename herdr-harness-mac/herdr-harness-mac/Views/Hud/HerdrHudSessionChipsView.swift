import SwiftUI

struct HerdrHudSessionChipsView: View {
    @Bindable var model: HerdrAppModel
    let chips: [HerdrHudSessionChips.Chip]
    let overflow: Int

    var body: some View {
        HStack(spacing: HerdrHudPlacement.chipSpacing) {
            ForEach(chips) { chip in
                chipButton(chip)
            }
        }
        .overlay(alignment: .topLeading) {
            if overflow > 0 {
                Text("+\(overflow)")
                    .herdrFont(.caption2, monospaced: true, weight: .bold)
                    .foregroundStyle(HerdrTheme.mist)
                    .padding(.horizontal, 4)
                    .background(HerdrTheme.graphite.opacity(0.94), in: .capsule)
                    .offset(x: -30, y: -12)
                    .accessibilityLabel("\(overflow) more sessions")
            }
        }
    }

    private func chipButton(_ chip: HerdrHudSessionChips.Chip) -> some View {
        Button {
            model.dismissHudChip(chip.id)
            HerdrMacAppDelegate.openPaneURLWithFallback(chip.id)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(chip.status.color)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(chip.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if chip.isMuted {
                    Image(systemName: "bell.slash.fill")
                        .herdrFont(.caption2)
                        .accessibilityHidden(true)
                }
            }
            .herdrFont(.caption2, monospaced: true, weight: .semibold)
            .foregroundStyle(HerdrTheme.text)
            .padding(.horizontal, 9)
            .frame(width: HerdrHudPlacement.chipWidth, height: HerdrTheme.minHitTarget)
            .herdrHitTarget(
                minWidth: HerdrHudPlacement.chipWidth,
                minHeight: HerdrTheme.minHitTarget
            )
            .background(HerdrTheme.elevated, in: .capsule)
            .overlay {
                Capsule().strokeBorder(chip.status.color.opacity(0.4), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .herdrPulseGlow(
            chip.status.color,
            isActive: chip.status == .working,
            diameter: HerdrTheme.minHitTarget
        )
        .contextMenu {
            Button(
                chip.isMuted ? "Unmute session" : "Mute session",
                systemImage: chip.isMuted ? "bell" : "bell.slash"
            ) {
                model.toggleMutedHudSession(chip.id)
            }
        }
        .accessibilityIdentifier("hud-session-chip-\(chip.id)")
        .accessibilityLabel("Open \(chip.title), \(chip.status.title)")
    }
}
