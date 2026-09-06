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
    var voiceReply: HerdrHudVoiceReply?
    var openVoiceRequest: ((String) -> Void)?

    @State private var hoveredChipID: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: HerdrHudPlacement.chipSpacing) {
            ForEach(chips) { chip in
                sessionRow(chip)
            }
            if overflow > 0 {
                overflowButton
            }
        }
    }

    private func sessionRow(_ chip: HerdrHudSessionChips.Chip) -> some View {
        HStack(spacing: 0) {
            if !chip.artifacts.isEmpty {
                HerdrHudResultArtifactRailView(model: model, artifacts: chip.artifacts)
            }

            chipButton(chip)
                .overlay(alignment: .trailing) {
                    if session.voiceReplyTarget == chip.id || voiceReply?.paneID == chip.id {
                        replyButton(chip)
                            .offset(x: 2, y: 12)
                    } else if chip.status == .done {
                        speakButton(chip)
                            .offset(x: 2, y: 12)
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
                // Matches the chips it stands in for — and the height the
                // collapsed panel reserves for this row.
                .frame(minHeight: HerdrHudPlacement.chipHeight)
                .herdrHitTarget(minHeight: HerdrHudPlacement.chipHeight)
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

    /// Offered once this chip's answer has finished playing. Recording happens
    /// right here — tap to talk, tap again to stop — so a spoken reply never
    /// drags the user into the HUD's own chat, which is a different agent.
    private func replyButton(_ chip: HerdrHudSessionChips.Chip) -> some View {
        let isRecording = voiceReply?.isRecording == true
        let isTranscribing = voiceReply?.phase == .transcribing
        return Button {
            guard let voiceReply else { return }
            voiceReply.target(paneID: chip.id, title: chip.title)
            Task { await voiceReply.toggleCapture(gateway: HerdrLiveVoiceReplyGateway(model: model)) }
        } label: {
            Group {
                if isTranscribing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: isRecording ? "record.circle.fill" : "mic.circle.fill")
                        .herdrFont(.caption2, weight: .bold)
                        .foregroundStyle(isRecording ? HerdrTheme.alert : HerdrTheme.accent)
                }
            }
            .frame(width: 20, height: 20)
            .background(HerdrTheme.graphite, in: .circle)
            .overlay {
                Circle().strokeBorder(
                    (isRecording ? HerdrTheme.alert : HerdrTheme.accent).opacity(isRecording ? 0.9 : 0.45),
                    lineWidth: 1
                )
            }
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(isTranscribing)
        .help(isRecording ? "Stop recording" : "Reply to this session by voice")
        .accessibilityLabel(isRecording ? "Stop recording" : "Reply by voice")
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
            if model.pane(id: chip.id) == nil, let noteID = chip.voiceNoteID {
                openVoiceRequest?(noteID)
            } else {
                model.dismissHudChip(chip.id)
                HerdrMacAppDelegate.openPaneURLWithFallback(chip.id)
            }
        } label: {
            HerdrHudSessionBubbleLabel(chip: chip)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let noteID = chip.voiceNoteID {
                Button("Show voice request", systemImage: "waveform") { openVoiceRequest?(noteID) }
            }
            Button(
                chip.isMuted ? "Unmute session" : "Mute session",
                systemImage: chip.isMuted ? "bell" : "bell.slash"
            ) {
                model.toggleMutedHudSession(chip.id)
            }
        }
        .accessibilityIdentifier("hud-session-chip-\(chip.id)")
        .accessibilityLabel("Open \(chip.title), \(chip.statusLabel)")
        .help("\(chip.title): \(chip.statusLabel)")
    }
}
