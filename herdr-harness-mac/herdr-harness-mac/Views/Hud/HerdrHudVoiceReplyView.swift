import SwiftUI

/// Reply-by-voice strip, shown inside the expanded card once the HUD has
/// finished reading an agent's answer aloud. Built inline rather than as a
/// sheet: the card is exactly `HerdrHudPlacement.expandedSize` and sheets from a
/// borderless nonactivating panel are unreliable.
struct HerdrHudVoiceReplyView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var session: HerdrHudSession
    @Bindable var voiceReply: HerdrHudVoiceReply

    private var gateway: HerdrLiveVoiceReplyGateway { HerdrLiveVoiceReplyGateway(model: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch voiceReply.phase {
            case .idle:
                micCTA
            case .recording:
                recordingRow
            case .transcribing:
                statusRow("Transcribing…", showsProgress: true)
            case .editing:
                editor
            case .sending:
                statusRow("Sending…", showsProgress: true)
            case .sent:
                statusRow("Sent", showsProgress: false)
            case let .failed(message):
                failureRow(message)
            }
        }
        .padding(.horizontal, HerdrTheme.cardPadding)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HerdrTheme.ink.opacity(0.4))
        .accessibilityIdentifier("hud-voice-reply-strip")
        .onDisappear { voiceReply.cancel() }
    }

    private var micCTA: some View {
        Button {
            voiceReply.start()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "mic.circle.fill")
                    .herdrFont(.title3)
                    .foregroundStyle(HerdrTheme.accent)
                Text("Reply by voice")
                    .herdrFont(.caption, weight: .semibold)
                    .foregroundStyle(HerdrTheme.text)
            }
            .herdrHitTarget()
        }
        .buttonStyle(.plain)
        // Never name the session here: titles are redacted when the user has
        // hidden them, but the pane id stays real.
        .accessibilityLabel("Reply by voice")
        .accessibilityIdentifier("hud-voice-reply")
    }

    private var recordingRow: some View {
        HStack(spacing: 8) {
            HerdrVoiceWaveform(samples: voiceReply.samples, isRecording: true, showsContainer: false)
                .frame(height: 22)
            Button {
                Task { await voiceReply.stopAndTranscribe(gateway: gateway) }
            } label: {
                Image(systemName: "stop.circle.fill")
                    .herdrFont(.title3)
                    .foregroundStyle(HerdrTheme.alert)
                    .herdrHitTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop recording")
            .accessibilityIdentifier("hud-voice-reply-stop")
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            if voiceReply.usedFallback {
                Text("Parakeet unavailable · transcribed with Apple Speech")
                    .herdrFont(.caption2)
                    .foregroundStyle(HerdrTheme.muted)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Edit your reply", text: $voiceReply.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(1...4)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(HerdrTheme.graphite, in: .rect(cornerRadius: HerdrTheme.compactRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                            .strokeBorder(HerdrTheme.surface, lineWidth: 1)
                    }
                    .accessibilityIdentifier("hud-voice-reply-draft")
                Button {
                    Task { await voiceReply.send(gateway: gateway) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .herdrFont(.title3)
                        .foregroundStyle(voiceReply.canSend ? HerdrTheme.accent : HerdrTheme.muted)
                        .herdrHitTarget()
                }
                .buttonStyle(.plain)
                .disabled(!voiceReply.canSend)
                .accessibilityLabel("Send voice reply")
                .accessibilityIdentifier("hud-voice-reply-send")
            }
            HStack(spacing: 12) {
                Button("Re-record") { voiceReply.reset(); voiceReply.start() }
                    .buttonStyle(.plain)
                    .herdrFont(.caption2, weight: .semibold)
                    .foregroundStyle(HerdrTheme.mist)
                Button("Discard") { dismiss() }
                    .buttonStyle(.plain)
                    .herdrFont(.caption2, weight: .semibold)
                    .foregroundStyle(HerdrTheme.mist)
            }
        }
    }

    private func statusRow(_ title: String, showsProgress: Bool) -> some View {
        HStack(spacing: 6) {
            if showsProgress {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(HerdrTheme.success)
            }
            Text(title)
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.mist)
        }
    }

    private func failureRow(_ message: String) -> some View {
        HStack(spacing: 8) {
            Text(message)
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.alert)
            Spacer(minLength: 0)
            Button("Retry") { voiceReply.start() }
                .buttonStyle(.plain)
                .herdrFont(.caption2, weight: .semibold)
                .foregroundStyle(HerdrTheme.accent)
            Button("Dismiss") { dismiss() }
                .buttonStyle(.plain)
                .herdrFont(.caption2, weight: .semibold)
                .foregroundStyle(HerdrTheme.mist)
        }
    }

    /// Clearing the session's target is what unmounts this strip.
    private func dismiss() {
        voiceReply.cancel()
        session.clearVoiceReplyTarget()
    }
}
