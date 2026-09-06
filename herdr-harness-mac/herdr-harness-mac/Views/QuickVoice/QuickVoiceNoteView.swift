import SwiftUI

/// A receipt for one request. Agent progress lives in the HUD notifications;
/// acknowledgments do not compete with the transcript or final report here.
struct QuickVoiceNoteView: View {
    let note: QuickVoiceSession.Note
    let session: QuickVoiceSession
    let model: HerdrAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Heard you", systemImage: "checkmark.circle.fill")
                .herdrFont(.headline).foregroundStyle(HerdrTheme.signal)
            Text(note.job.text)
                .herdrFont(.body).textSelection(.enabled)
                .accessibilityIdentifier("quick-voice-confirmed-transcript")
            Label(note.job.statusLabel, systemImage: note.job.statusSymbol)
                .herdrFont(.callout, weight: .semibold)
                .foregroundStyle(note.job.needsAttention ? HerdrTheme.warning : HerdrTheme.accent)
            if let error = note.job.error {
                Text(error).herdrFont(.callout).foregroundStyle(HerdrTheme.warning).textSelection(.enabled)
            }
            if let report = note.job.messages.first(where: { $0.id == "report" }) {
                Divider()
                Text(report.text).herdrFont(.callout).textSelection(.enabled)
                Button(session.playingMessageID == note.id + ":report" ? "Stop report" : "Listen to report", systemImage: session.playingMessageID == note.id + ":report" ? "stop.circle" : "play.circle") {
                    if session.playingMessageID == note.id + ":report" { session.stopAudio() }
                    else { session.play(note: note, message: report) }
                }
                .buttonStyle(.plain).foregroundStyle(HerdrTheme.accent)
                .disabled(report.audioStatus != "ready")
                if report.audioStatus == "failed" {
                    Text("Audio unavailable. Your report is saved above.").herdrFont(.callout).foregroundStyle(HerdrTheme.mist)
                }
                DisclosureGroup("Agent chats") {
                    ForEach(note.job.tasks) { task in
                        Button(model.showSessionTitles ? task.title : "Agent", systemImage: task.statusSymbol) {
                            session.openAgent(task, in: note)
                        }
                        .buttonStyle(.plain).disabled(task.paneID == nil)
                        .padding(.vertical, 4)
                    }
                }
                .herdrFont(.callout)
            } else {
                Text(note.job.tasks.isEmpty ? "Finding the work that can run in parallel." : "Follow your agents below. You can record another request while they work.")
                    .herdrFont(.callout).foregroundStyle(HerdrTheme.mist)
            }
        }
    }
}
