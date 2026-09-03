import SwiftUI

/// The spoken reply, reviewed on its own small surface beside the orb.
///
/// Deliberately not part of the HUD chat: a reply goes to another agent's pi
/// session, and showing it inside the HUD's own transcript made it read as a
/// prompt to the HUD. Recording and transcribing stay on the chip; this appears
/// only once there is a transcript to read.
struct HerdrHudVoiceReplyCardView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var voiceReply: HerdrHudVoiceReply

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isDraftFocused: Bool

    private var gateway: HerdrLiveVoiceReplyGateway { HerdrLiveVoiceReplyGateway(model: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
        }
        .padding(12)
        .frame(
            width: HerdrHudPlacement.voiceReplyCardSize.width,
            height: HerdrHudPlacement.voiceReplyCardSize.height,
            alignment: .top
        )
        .background(HerdrTheme.graphite, in: .rect(cornerRadius: HerdrTheme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                .strokeBorder(HerdrTheme.surface, lineWidth: 1)
        }
        .shadow(color: HerdrTheme.ink.opacity(0.55), radius: 18, y: 8)
        .accessibilityIdentifier("hud-voice-reply-card")
        .onAppear { isDraftFocused = true }
        // NSTextView swallows cancelOperation, so Escape needs its own handler.
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "mic.fill")
                .herdrFont(.caption2, weight: .bold)
                .foregroundStyle(HerdrTheme.accent)
            Text(voiceReply.paneTitle.isEmpty ? "Voice reply" : voiceReply.paneTitle)
                .herdrFont(.caption, weight: .semibold)
                .foregroundStyle(HerdrTheme.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .herdrFont(.caption2, weight: .bold)
                    .foregroundStyle(HerdrTheme.mist)
                    .herdrHitTarget(minWidth: 0)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Discard voice reply")
            .accessibilityIdentifier("hud-voice-reply-close")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch voiceReply.phase {
        case .sending:
            status("Sending…", showsProgress: true)
        case .sent:
            status("Sent", showsProgress: false)
        case let .failed(message):
            failure(message)
        default:
            editor
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Your reply", text: $voiceReply.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.text)
                .focused($isDraftFocused)
                .lineLimit(3...5)
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(HerdrTheme.ink.opacity(0.5), in: .rect(cornerRadius: HerdrTheme.compactRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                        .strokeBorder(HerdrTheme.surface, lineWidth: 1)
                }
                .accessibilityIdentifier("hud-voice-reply-draft")

            HStack(spacing: 8) {
                if voiceReply.usedFallback {
                    Text("Apple Speech")
                        .herdrFont(.caption2)
                        .foregroundStyle(HerdrTheme.muted)
                }
                Spacer(minLength: 0)
                Button(action: send) {
                    Label("Send", systemImage: "arrow.up.circle.fill")
                        .herdrFont(.caption, weight: .semibold)
                        .foregroundStyle(voiceReply.canSend ? HerdrTheme.accent : HerdrTheme.muted)
                        .herdrHitTarget(minWidth: 0)
                }
                .buttonStyle(.plain)
                .disabled(!voiceReply.canSend)
                .accessibilityIdentifier("hud-voice-reply-send")
            }
        }
    }

    private func status(_ title: String, showsProgress: Bool) -> some View {
        HStack(spacing: 6) {
            if showsProgress {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(HerdrTheme.success)
            }
            Text(title)
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.mist)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.alert)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Try again") { voiceReply.start() }
                    .buttonStyle(.plain)
                    .herdrFont(.caption2, weight: .semibold)
                    .foregroundStyle(HerdrTheme.accent)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func send() {
        Task { await voiceReply.send(gateway: gateway) }
    }

    private func dismiss() {
        voiceReply.cancel()
    }
}
