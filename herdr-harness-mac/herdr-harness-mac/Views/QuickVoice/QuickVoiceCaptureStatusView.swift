import SwiftUI

struct QuickVoiceCaptureStatusView: View {
    let session: QuickVoiceSession

    var body: some View {
        if session.phase == .recording {
            HStack {
                Label("Recording · \(Int(session.recorder.elapsedTime))s", systemImage: "record.circle")
                    .foregroundStyle(.red)
                Spacer()
                Button("Discard", action: session.cancelRecording)
            }
            Text("Stop and send starts your side quests automatically.").font(.caption).foregroundStyle(.secondary)
        } else if session.phase == .transcribing || session.phase == .submitting {
            HStack {
                ProgressView().controlSize(.small)
                Text(session.phase == .transcribing ? "Transcribing your note…" : "Sending to your assistant…")
            }
        }
        if let error = session.error {
            Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            if !session.transcript.isEmpty {
                Text(session.transcript).font(.callout).textSelection(.enabled)
            }
            HStack {
                if session.hasPendingSubmission || session.recorder.canSave {
                    Button("Try again", action: session.retry).disabled(session.phase != .idle)
                }
                if !session.hasPendingSubmission {
                    Button("Dismiss", action: session.dismissError)
                } else {
                    Button("Keep any chats and clear note", action: session.clearPendingNote)
                        .disabled(session.phase != .idle)
                }
            }
        }
    }
}
