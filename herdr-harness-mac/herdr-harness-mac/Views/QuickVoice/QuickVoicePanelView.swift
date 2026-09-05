import SwiftUI

struct QuickVoicePanelView: View {
    let controller: QuickVoicePanelController
    @Bindable var session: QuickVoiceSession
    let model: HerdrAppModel
    let fontScale: HerdrFontScaleStore

    var body: some View {
        VStack(spacing: 12) {
            if controller.isExpanded {
                QuickVoiceDetailsView(controller: controller, session: session, model: model)
            }
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 32)
                    .overlay(HerdrHudWindowDragHandle(onDragEnded: controller.savePosition))
                    .accessibilityLabel("Drag voice capture")
                Button(session.phase == .recording ? "Stop and send voice note" : "Record quick voice note", systemImage: session.phase == .recording ? "stop.fill" : "mic.fill", action: controller.capture)
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(session.phase == .recording ? Color.red : HerdrTheme.accent, in: Circle())
                    .foregroundStyle(.black)
                    .buttonStyle(.plain)
                    .disabled(!session.canCapture && session.phase != .recording)
                    .help(session.phase == .recording ? "Stop recording and send to your assistant" : "Record a quick voice note")
                    .accessibilityIdentifier("quick-voice-microphone")
                Button("Voice notes and reports", systemImage: session.activeCount > 0 ? "waveform.badge.magnifyingglass" : "text.bubble", action: controller.toggleDetails)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(HerdrTheme.accent)
                    .overlay(alignment: .topTrailing) {
                        if session.activeCount > 0 {
                            Text("\(session.activeCount)").font(.caption2).offset(x: 8, y: -12)
                        }
                    }
                    .accessibilityIdentifier("quick-voice-history")
            }
            .padding(controller.isExpanded ? 0 : 10)
        }
        .padding(controller.isExpanded ? 16 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(HerdrTheme.ink.opacity(0.97), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(HerdrTheme.accent.opacity(0.3)))
        .padding(6)
        .environment(\.herdrFontScale, fontScale.scale)
        .preferredColorScheme(.dark)
        .onChange(of: session.recorder.status) { _, _ in session.recordingStateChanged() }
        .onChange(of: session.recorder.errorMessage) { _, _ in session.recordingStateChanged() }
    }
}
