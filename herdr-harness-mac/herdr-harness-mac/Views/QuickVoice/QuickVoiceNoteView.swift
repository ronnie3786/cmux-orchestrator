import AppKit
import SwiftUI

struct QuickVoiceNoteView: View {
    let note: QuickVoiceSession.Note
    let session: QuickVoiceSession
    let model: HerdrAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.showSessionTitles ? note.job.title : "Voice side quest").font(.headline)
            Text(note.job.statusLabel).font(.caption).foregroundStyle(note.job.status == "done" ? HerdrTheme.accent : .secondary)
            DisclosureGroup("Your voice note") {
                Text(note.job.text).font(.callout).textSelection(.enabled)
            }
            ForEach(note.job.tasks) { task in
                Button {
                    open(task)
                } label: {
                    Label(model.showSessionTitles ? task.title : "Side quest", systemImage: task.status == "done" ? "checkmark.circle" : task.status == "needs_attention" || task.status == "failed" ? "exclamationmark.circle" : "bubble.left")
                        .font(.callout).multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain).foregroundStyle(HerdrTheme.accent)
                .disabled(task.paneID == nil)
            }
            ForEach(note.job.messages) { message in
                VStack(alignment: .leading, spacing: 6) {
                    Text(message.text).font(.callout).textSelection(.enabled)
                    Button(message.id == "ack" ? "Replay acknowledgment" : "Replay report", systemImage: "play.circle") {
                        session.play(note: note, message: message)
                    }
                    .buttonStyle(.plain).foregroundStyle(HerdrTheme.accent)
                    .disabled(message.audioStatus != "ready" || session.phase == .recording || session.phase == .transcribing)
                    if message.audioStatus == "failed" {
                        Text("Audio unavailable. Your text report is saved.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(12)
        .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 16))
    }

    private func open(_ task: QuickVoiceJob.Quest) {
        guard let paneID = task.paneID,
              let pane = model.workspaces.flatMap(\.panes).first(where: { $0.machineID == note.machineID && $0.paneID == paneID })
        else {
            Task { await model.refresh() }
            return
        }
        HerdrMacAppDelegate.openPaneURLWithFallback(pane.id)
    }
}
