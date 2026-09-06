import SwiftUI

/// The microphone's satellite stays inside the orb row's hit-test bounds.
struct QuickVoicePanelView: View {
    let controller: QuickVoicePanelController
    let session: QuickVoiceSession

    var body: some View {
        Button(
            session.phase == .recording ? "Stop and send" : "Record a voice request",
            systemImage: session.phase == .recording ? "stop.fill" : "mic.fill",
            action: controller.capture
        )
        .labelStyle(.iconOnly)
        .herdrFont(.callout, weight: .bold)
        .foregroundStyle(session.phase == .recording ? HerdrTheme.ink : HerdrTheme.text)
        .frame(width: 32, height: 32)
        .background(session.phase == .recording ? HerdrTheme.alert : HerdrTheme.elevated, in: .circle)
        .overlay { Circle().strokeBorder(HerdrTheme.graphite, lineWidth: 3) }
        .contentShape(.circle)
        .buttonStyle(.plain)
        .disabled(session.phase == .transcribing || session.phase == .submitting)
        .help(session.phase == .recording ? "Stop and send to your agents" : "Speak a request to start agents (⌃⌘V)")
        .accessibilityIdentifier("quick-voice-microphone")
        .contextMenu {
            Button("Voice requests and reports") { controller.showDetails() }
        }
    }
}
