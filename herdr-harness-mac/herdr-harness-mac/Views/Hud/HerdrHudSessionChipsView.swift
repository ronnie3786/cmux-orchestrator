import SwiftUI

enum HerdrHudChipMotion {
    static let workingGlowOpacity = 0.55

    /// HUD chips are permanently mounted beside the orb, so their working
    /// signal stays static. A static shadow preserves the visual cue without
    /// adding one perpetual display-link animation per chip.
    static func showsStaticGlow(for status: AgentStatus) -> Bool {
        status == .working
    }
}

struct HerdrHudSessionChipsView: View {
    @Bindable var model: HerdrAppModel
    let chips: [HerdrHudSessionChips.Chip]
    let overflow: Int

    var body: some View {
        VStack(alignment: .trailing, spacing: HerdrHudPlacement.chipSpacing) {
            ForEach(chips) { chip in
                chipButton(chip)
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .herdrFont(.caption2, monospaced: true, weight: .bold)
                    .foregroundStyle(HerdrTheme.mist)
                    .padding(.horizontal, 4)
                    .background(HerdrTheme.graphite.opacity(0.94), in: .capsule)
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
                    .shadow(
                        color: HerdrHudChipMotion.showsStaticGlow(for: chip.status)
                            ? chip.status.color.opacity(HerdrHudChipMotion.workingGlowOpacity)
                            : .clear,
                        radius: 3
                    )
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
