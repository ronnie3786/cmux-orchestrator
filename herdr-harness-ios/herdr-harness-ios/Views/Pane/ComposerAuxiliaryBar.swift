import SwiftUI

/// The expandable utility row shown above the pane composer.
///
/// The view is intentionally closure-driven so the composer owns presentation
/// and networking state while this control stays reusable and previewable.
struct ComposerAuxiliaryBar: View {
    let attach: () -> Void
    let recordVoice: () -> Void
    let searchFiles: () -> Void
    let chooseJira: () -> Void
    let voicePhase: HerdrQuickVoiceCapture.Phase
    let beginVoiceHold: () -> Void
    let endVoiceHold: () -> Void

    @State private var hapticPulse = HerdrHapticPulse()

    var body: some View {
        ViewThatFits(in: .horizontal) {
            controls(showsTitles: true)
            controls(showsTitles: false)
        }
        .herdrHaptic(trigger: hapticPulse)
    }

    private func controls(showsTitles: Bool) -> some View {
        HStack(spacing: 8) {
            auxiliaryButton(
                title: "attach",
                systemImage: "paperclip",
                accessibilityLabel: "Attach a file",
                showsTitle: showsTitles,
                action: attach
            )
            voiceButton(showsTitle: showsTitles)
            auxiliaryButton(
                title: "@ file",
                systemImage: "at",
                accessibilityLabel: "Insert a workspace file path",
                showsTitle: showsTitles,
                action: searchFiles
            )
            auxiliaryButton(
                title: "jira",
                systemImage: "ticket",
                accessibilityLabel: "Insert Jira ticket context",
                showsTitle: showsTitles,
                action: chooseJira
            )
        }
    }

    private func auxiliaryButton(
        title: LocalizedStringKey,
        systemImage: String,
        accessibilityLabel: LocalizedStringKey,
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
            .foregroundStyle(HerdrTheme.mist)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, showsTitle ? 8 : 12)
            .background(HerdrTheme.elevated)
            .overlay {
                RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                    .strokeBorder(HerdrTheme.surface, lineWidth: 1)
            }
            .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func voiceButton(showsTitle: Bool) -> some View {
        HStack(spacing: 7) {
            if voicePhase == .transcribing {
                ProgressView()
                    .tint(HerdrTheme.mist)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "mic.fill")
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
        .onTapGesture {
            guard voicePhase == .idle else { return }
            hapticPulse.fire(.selection)
            recordVoice()
        }
        .gesture(
            LongPressGesture(minimumDuration: 0.35)
                .onEnded { _ in beginVoiceHold() }
                .sequenced(before: DragGesture(minimumDistance: 0))
                .onEnded { _ in endVoiceHold() }
        )
        .allowsHitTesting(voicePhase != .transcribing)
        .accessibilityLabel("Record a voice note")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the voice recorder. Press and hold to dictate into the prompt.")
    }

    private var voiceForeground: Color {
        voicePhase == .recording ? HerdrTheme.ink : HerdrTheme.mist
    }

    private var voiceBackground: Color {
        voicePhase == .recording ? HerdrTheme.alert : HerdrTheme.elevated
    }

    private var voiceBorder: Color {
        voicePhase == .recording ? HerdrTheme.alert : HerdrTheme.surface
    }
}
