import SwiftUI

/// The expandable utility row shown above the pane composer.
///
/// The view is intentionally closure-driven so the composer owns presentation
/// and networking state while this control stays reusable and previewable.
///
/// Mac notes: the gestures are the iOS ones verbatim — a click opens the voice
/// note sheet, a press-and-hold dictates — because that muscle memory is the
/// point of this bar. What the Mac adds is discoverability the phone did not
/// need: hover lifts each control and `.help` spells out what a hold does.
struct ComposerAuxiliaryBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let attach: () -> Void
    let recordVoice: () -> Void
    let searchFiles: () -> Void
    let chooseJira: () -> Void
    let voicePhase: HerdrQuickVoiceCapture.Phase
    let beginVoiceHold: () -> Void
    let endVoiceHold: () -> Void
    let finishLockedVoiceCapture: () -> Void

    @State private var hapticPulse = HerdrHapticPulse()
    @State private var isLockPulsing = false
    @State private var hoveredControl: String?

    /// Hover identity for the voice control, which `auxiliaryButton` does not
    /// build because of its gesture and phase handling.
    private static let voiceControl = "voice"

    var body: some View {
        ViewThatFits(in: .horizontal) {
            controls(showsTitles: true)
            controls(showsTitles: false)
        }
        .herdrHaptic(trigger: hapticPulse)
        .onChange(of: voicePhase) { _, phase in
            isLockPulsing = phase == .locked
            if phase == .transcribing, hoveredControl == Self.voiceControl {
                hoveredControl = nil
            }
        }
        .onAppear {
            isLockPulsing = voicePhase == .locked
        }
    }

    private func controls(showsTitles: Bool) -> some View {
        HStack(spacing: 8) {
            auxiliaryButton(
                identity: "attach",
                title: "attach",
                systemImage: "paperclip",
                accessibilityLabel: "Attach a file",
                help: "Attach files to this prompt",
                showsTitle: showsTitles,
                action: attach
            )
            voiceButton(showsTitle: showsTitles)
            auxiliaryButton(
                identity: "file",
                title: "@ file",
                systemImage: "at",
                accessibilityLabel: "Insert a workspace file path",
                help: "Search this workspace and insert a file path",
                showsTitle: showsTitles,
                action: searchFiles
            )
            auxiliaryButton(
                identity: "jira",
                title: "jira",
                systemImage: "ticket",
                accessibilityLabel: "Insert Jira ticket context",
                help: "Insert Jira ticket context",
                showsTitle: showsTitles,
                action: chooseJira
            )
        }
    }

    private func auxiliaryButton(
        identity: String,
        title: LocalizedStringKey,
        systemImage: String,
        accessibilityLabel: LocalizedStringKey,
        help: LocalizedStringKey,
        showsTitle: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            hapticPulse.fire(.selection)
            action()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))

                if showsTitle {
                    Text(title)
                        .font(.caption.monospaced().weight(.semibold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(hoveredControl == identity ? HerdrTheme.text : HerdrTheme.mist)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, showsTitle ? 8 : 12)
            .background(HerdrTheme.elevated)
            .overlay {
                RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                    .strokeBorder(
                        hoveredControl == identity ? HerdrTheme.accent.opacity(0.45) : HerdrTheme.surface,
                        lineWidth: 1
                    )
            }
            .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            hoveredControl = isHovering ? identity : (hoveredControl == identity ? nil : hoveredControl)
        }
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }

    private func voiceButton(showsTitle: Bool) -> some View {
        HStack(spacing: 7) {
            if voicePhase == .transcribing {
                ProgressView()
                    .tint(HerdrTheme.mist)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: voicePhase == .locked ? "lock.fill" : "mic.fill")
                    .font(.subheadline.weight(.semibold))
            }

            if showsTitle {
                Text("voice")
                    .font(.caption.monospaced().weight(.semibold))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(voiceForeground)
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.horizontal, showsTitle ? 8 : 12)
        .background(voiceBackground)
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(voiceBorder, lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
        .contentShape(.rect)
        .scaleEffect(voicePhase == .locked && isLockPulsing && !reduceMotion ? 1.035 : 1)
        .opacity(voicePhase == .locked && isLockPulsing && !reduceMotion ? 0.86 : 1)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
            value: isLockPulsing
        )
        .onTapGesture {
            switch voicePhase {
            case .idle:
                hapticPulse.fire(.selection)
                recordVoice()
            case .locked:
                finishLockedVoiceCapture()
            case .recording, .transcribing:
                break
            }
        }
        .gesture(
            LongPressGesture(minimumDuration: 0.35)
                .onEnded { _ in beginVoiceHold() }
                .sequenced(before: DragGesture(minimumDistance: 0))
                .onEnded { _ in endVoiceHold() }
        )
        .allowsHitTesting(voicePhase != .transcribing)
        .onHover { isHovering in
            hoveredControl = isHovering ? Self.voiceControl : (hoveredControl == Self.voiceControl ? nil : hoveredControl)
        }
        .help(voiceHelp)
        .accessibilityLabel("Record a voice note")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the voice recorder. Press and hold to dictate into the prompt.")
    }

    private var voiceForeground: Color {
        if isRecordingOrLocked { return HerdrTheme.ink }
        return hoveredControl == Self.voiceControl ? HerdrTheme.text : HerdrTheme.mist
    }

    private var voiceBackground: Color {
        isRecordingOrLocked ? HerdrTheme.alert : HerdrTheme.elevated
    }

    private var voiceBorder: Color {
        if isRecordingOrLocked { return HerdrTheme.alert }
        return hoveredControl == Self.voiceControl ? HerdrTheme.accent.opacity(0.45) : HerdrTheme.surface
    }

    /// The one place the hold-to-dictate gesture is spelled out for a pointer.
    private var voiceHelp: String {
        switch voicePhase {
        case .idle:
            "Click to record a voice note · press and hold to dictate into the prompt"
        case .recording:
            "Dictating — release to transcribe, keep holding to lock"
        case .locked:
            "Recording locked — click to finish and transcribe"
        case .transcribing:
            "Transcribing this dictation"
        }
    }

    private var isRecordingOrLocked: Bool {
        voicePhase == .recording || voicePhase == .locked
    }
}
