import AppKit
import SwiftUI

struct HerdrHudComposerView: View {
    @Bindable var model: HerdrAppModel
    let controller: HerdrHudController
    @Bindable var session: HerdrHudSession

    @FocusState private var isComposerFocused: Bool
    @State private var quickVoiceCapture = HerdrQuickVoiceCapture()
    @State private var voiceErrorMessage: String?

    var body: some View {
        VStack(spacing: 8) {
            if let clipboardAttachment = session.clipboardAttachment {
                clipboardChip(clipboardAttachment)
            }
            if let voiceErrorMessage, !voiceErrorMessage.isEmpty {
                Text(voiceErrorMessage)
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.alert)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                composerInput
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .herdrFont(.title3)
                        .foregroundStyle(HerdrTheme.accent)
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .accessibilityLabel("Send HUD prompt")
                .accessibilityIdentifier("hud-send")
            }
            HStack(spacing: 8) {
                Button(action: toggleVoiceCapture) {
                    Image(systemName: isVoiceCaptureActive ? "mic.fill" : "mic")
                        .foregroundStyle(isVoiceCaptureActive ? HerdrTheme.alert : HerdrTheme.mist)
                }
                .buttonStyle(.plain)
                .disabled(quickVoiceCapture.phase == .transcribing)
                .accessibilityLabel(voiceCaptureAccessibilityLabel)
                .accessibilityIdentifier("hud-mic")

                Button(action: attachClipboard) {
                    Image(systemName: "doc.on.clipboard")
                        .foregroundStyle(HerdrTheme.mist)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Attach clipboard")
                .accessibilityIdentifier("hud-clipboard")

                Spacer()

                Picker("Mode", selection: $session.mode) {
                    Label("Ask", systemImage: "sparkles").tag(HeadlessAgentRunMode.ask)
                    Label("Do", systemImage: "bolt.fill").tag(HeadlessAgentRunMode.act)
                }
                .pickerStyle(.segmented)
                .frame(width: 122)
                .herdrFont(.caption, weight: .bold)
                .accessibilityIdentifier("hud-mode-picker")
            }
        }
        .padding(12)
        .task(id: controller.focusRequest) {
            isComposerFocused = true
        }
        .onDisappear {
            quickVoiceCapture.cancel()
        }
        .onChange(of: quickVoiceCapture.recorderStatus) { _, status in
            if status == .finished, quickVoiceCapture.phase == .locked {
                finishVoiceCapture()
            }
        }
    }

    @ViewBuilder
    private var composerInput: some View {
        Group {
            if isVoiceCaptureActive {
                HerdrVoiceWaveform(
                    samples: quickVoiceCapture.samples,
                    isRecording: true,
                    showsContainer: false
                )
                .padding(.horizontal, 10)
            } else if quickVoiceCapture.phase == .transcribing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(HerdrTheme.accent)
                    Text("Transcribing…")
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.mist)
                }
                .frame(maxWidth: .infinity, minHeight: 42)
            } else {
                TextField(placeholder, text: $session.draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .herdrFont(.callout)
                    .foregroundStyle(HerdrTheme.text)
                    .focused($isComposerFocused)
                    .onSubmit(submit)
                    .onKeyPress(.return, phases: .down, action: handleReturnKey)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .background(HerdrTheme.elevated, in: .rect(cornerRadius: HerdrTheme.compactRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(isComposerFocused ? HerdrTheme.accent : HerdrTheme.surface, lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
    }

    private var placeholder: String {
        session.mode == .ask ? "Ask your fleet…" : "Tell it what to do…"
    }

    private var canSubmit: Bool {
        !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !session.isRunning
    }

    private var isVoiceCaptureActive: Bool {
        quickVoiceCapture.phase == .recording || quickVoiceCapture.phase == .locked
    }

    private var voiceCaptureAccessibilityLabel: String {
        switch quickVoiceCapture.phase {
        case .idle: "Start voice dictation"
        case .recording, .locked: "Stop voice dictation and transcribe"
        case .transcribing: "Voice dictation is transcribing"
        }
    }

    private func clipboardChip(_ attachment: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard")
                .foregroundStyle(HerdrTheme.accent)
            Text("\(attachment.count) chars")
                .herdrFont(.caption, monospaced: true)
                .foregroundStyle(HerdrTheme.mist)
            Button {
                session.clipboardAttachment = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(HerdrTheme.mist)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove clipboard attachment")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(HerdrTheme.elevated, in: .rect(cornerRadius: HerdrTheme.compactRadius))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func handleReturnKey(_ press: KeyPress) -> KeyPress.Result {
        guard !press.modifiers.contains(.shift), !press.modifiers.contains(.option) else {
            return .ignored
        }
        submit()
        return .handled
    }

    private func submit() {
        guard canSubmit else { return }
        Task { await session.submit(model: model) }
    }

    private func attachClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        session.attachClipboard(text)
    }

    private func toggleVoiceCapture() {
        voiceErrorMessage = nil
        switch quickVoiceCapture.phase {
        case .idle:
            quickVoiceCapture.beginLocked()
        case .recording, .locked:
            finishVoiceCapture()
        case .transcribing:
            break
        }
    }

    private func finishVoiceCapture() {
        Task {
            let outcome = await quickVoiceCapture.endHold { url in
                try await model.transcribeVoiceNote(at: url)
            }
            handleVoiceCapture(outcome)
        }
    }

    private func handleVoiceCapture(_ outcome: HerdrQuickVoiceCapture.Outcome) {
        switch outcome {
        case .cancelled:
            break
        case .tooShort:
            voiceErrorMessage = "Hold the mic a little longer."
        case let .failure(message):
            voiceErrorMessage = message
        case let .transcript(transcript):
            let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            session.draft = session.draft.isEmpty ? text : "\(session.draft)\n\n\(text)"
        }
    }
}
