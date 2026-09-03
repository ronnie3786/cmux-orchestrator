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
    @Bindable var session: HerdrHudSession
    let chips: [HerdrHudSessionChips.Chip]
    let overflow: Int
    var showAll: () -> Void = { }
    var summon: () -> Void = { }

    @State private var hoveredChipID: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: HerdrHudPlacement.chipSpacing) {
            ForEach(chips) { chip in
                chipButton(chip)
                    .overlay(alignment: .trailing) {
                        if session.voiceReplyTarget == chip.id {
                            replyButton(chip)
                                .padding(.trailing, 5)
                        } else if chip.status == .done {
                            speakButton(chip)
                                .padding(.trailing, 5)
                                .opacity(showsSpeakButton(chip) ? 1 : 0)
                                .allowsHitTesting(showsSpeakButton(chip))
                        }
                    }
                    .onHover { hovering in
                        if hovering {
                            hoveredChipID = chip.id
                        } else if hoveredChipID == chip.id {
                            hoveredChipID = nil
                        }
                    }
            }
            if overflow > 0 {
                overflowButton
            }
        }
    }

    /// The grouped-session control. Clicking it reveals the sessions the chip
    /// limit folded away; the HUD regroups them a few seconds after the pointer
    /// leaves the stack.
    private var overflowButton: some View {
        Button(action: showAll) {
            Text("+\(overflow)")
                .herdrFont(.caption2, monospaced: true, weight: .bold)
                .foregroundStyle(HerdrTheme.mist)
                .padding(.horizontal, 9)
                .frame(minHeight: HerdrTheme.minHitTarget)
                .herdrHitTarget()
                .background(HerdrTheme.graphite.opacity(0.94), in: .capsule)
                .overlay {
                    Capsule().strokeBorder(HerdrTheme.surface, lineWidth: 1)
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help("Show \(overflow) more session\(overflow == 1 ? "" : "s")")
        .accessibilityIdentifier("hud-session-chip-overflow")
        .accessibilityLabel("\(overflow) more sessions")
        .accessibilityHint("Shows every session; they regroup shortly after you move away")
    }

    /// Offered once this chip's answer has finished playing. The collapsed HUD
    /// is far too narrow for an editable transcript, so this opens the card and
    /// lets the reply strip there take over.
    private func replyButton(_ chip: HerdrHudSessionChips.Chip) -> some View {
        Button(action: summon) {
            Image(systemName: "mic.circle.fill")
                .herdrFont(.caption2, weight: .bold)
                .foregroundStyle(HerdrTheme.accent)
                .frame(width: 20, height: 20)
                .background(HerdrTheme.graphite, in: .circle)
                .overlay {
                    Circle().strokeBorder(HerdrTheme.accent.opacity(0.45), lineWidth: 1)
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help("Reply to this session by voice")
        .accessibilityLabel("Reply by voice")
        .accessibilityIdentifier("hud-session-chip-reply-\(chip.id)")
    }

    private func showsSpeakButton(_ chip: HerdrHudSessionChips.Chip) -> Bool {
        hoveredChipID == chip.id || session.isSpeakingSession(chip.id)
    }

    /// The same TL;DR playback the chat composer offers, reachable without
    /// opening the session: hover a finished chip and press play.
    private func speakButton(_ chip: HerdrHudSessionChips.Chip) -> some View {
        Button {
            Task { await session.toggleSessionAudio(paneID: chip.id, model: model) }
        } label: {
            Group {
                if session.isPreparingSessionAudio(chip.id) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: speakSymbol(chip))
                        .herdrFont(.caption2, weight: .bold)
                }
            }
            .foregroundStyle(session.isSpeakingSession(chip.id) ? HerdrTheme.working : HerdrTheme.accent)
            .frame(width: 20, height: 20)
            .background(HerdrTheme.graphite, in: .circle)
            .overlay {
                Circle().strokeBorder(HerdrTheme.accent.opacity(0.45), lineWidth: 1)
            }
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help("Play a spoken summary of this session's last answer")
        .accessibilityIdentifier("hud-session-chip-speak-\(chip.id)")
        .accessibilityLabel("Listen to a summary of \(chip.title)")
    }

    private func speakSymbol(_ chip: HerdrHudSessionChips.Chip) -> String {
        guard session.isSpeakingSession(chip.id) else { return "speaker.wave.2.fill" }
        return session.responseAudioPlayer.phase == .paused(.tldr) ? "play.fill" : "pause.fill"
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
            .padding(.leading, 9)
            .padding(.trailing, chip.status == .done ? 29 : 9)
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
