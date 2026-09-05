import SwiftUI

struct QuickVoiceDetailsView: View {
    let controller: QuickVoicePanelController
    @Bindable var session: QuickVoiceSession
    let model: HerdrAppModel

    var body: some View {
        HStack {
            Text("Quick voice").font(.headline)
            Spacer()
            Button(session.isMuted ? "Unmute voice reports" : "Mute voice reports", systemImage: session.isMuted ? "speaker.slash" : "speaker.wave.2") { session.isMuted.toggle() }
                .labelStyle(.iconOnly).buttonStyle(.plain)
            Button("Collapse voice notes", systemImage: "chevron.down", action: controller.collapse)
                .labelStyle(.iconOnly).buttonStyle(.plain)
        }
        Picker("Run on", selection: $session.machineID) {
            Text("Choose a Mac").tag("")
            ForEach(model.machines) { machine in
                Text(machine.name).tag(machine.id)
            }
        }
        .disabled(session.phase != .idle || session.hasPendingSubmission)
        Text(session.contextFolder)
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
            .help("Working folder for the next voice note: \(session.contextFolder)")
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                QuickVoiceCaptureStatusView(session: session)
                if let error = session.connectionError {
                    Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                if session.notes.isEmpty {
                    Text("Click the microphone, speak, then click Stop and send. Your assistant starts side quests and reports back here.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Uses the selected chat’s folder when available. New chats appear in Quick Voice.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(session.notes) { note in
                    QuickVoiceNoteView(note: note, session: session, model: model)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if session.playingMessageID != nil {
            Button("Stop audio", systemImage: "stop.circle", action: session.stopAudio)
                .buttonStyle(.plain).foregroundStyle(HerdrTheme.accent)
        }
    }
}
