import SwiftUI

struct QuickVoiceCaptureStatusView: View {
    let session: QuickVoiceSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if session.phase == .recording {
                HStack {
                    Label(session.recorder.isRecording ? "Listening" : "Opening microphone…", systemImage: "record.circle.fill")
                        .herdrFont(.headline).foregroundStyle(HerdrTheme.alert)
                    Spacer()
                    Text("\(Int(session.recorder.elapsedTime))s").monospacedDigit()
                }
                HerdrVoiceWaveform(samples: session.recorder.samples, isRecording: true, showsContainer: false)
                Text("Say everything you want your agents to do.").foregroundStyle(HerdrTheme.mist)
                Button("Cancel recording", action: session.cancelRecording).buttonStyle(.plain)
            } else if session.phase == .transcribing || session.phase == .submitting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(session.phase == .transcribing ? "Turning your voice into text…" : "Sending your request…")
                        .herdrFont(.headline)
                }
                if !session.transcript.isEmpty {
                    Text(session.transcript).textSelection(.enabled)
                } else {
                    Text("Your recording is saved while we listen back.").foregroundStyle(HerdrTheme.mist)
                }
            } else if session.error == nil {
                Text("What do you need done?").herdrFont(.title3, weight: .semibold)
                Text("Ask for one thing or several. Your agents will appear below the orb.")
                    .foregroundStyle(HerdrTheme.mist)
                if !session.canCapture {
                    Text("Connect to a Mac to start a voice request.").foregroundStyle(HerdrTheme.warning)
                }
            }
            if let error = session.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .foregroundStyle(HerdrTheme.warning).textSelection(.enabled)
                if !session.transcript.isEmpty {
                    Text(session.transcript).textSelection(.enabled)
                }
                HStack {
                    if session.hasPendingSubmission || session.recorder.canSave {
                        Button("Try again", action: session.retry).disabled(session.phase != .idle)
                    }
                    if !session.hasPendingSubmission {
                        Button("Dismiss", action: session.dismissError)
                    } else {
                        Button("Clear this request", action: session.clearPendingNote).disabled(session.phase != .idle)
                    }
                }
                if session.hasPendingSubmission {
                    Text("Retry checks the same request. Clearing it leaves any agents already started running.")
                        .foregroundStyle(HerdrTheme.mist)
                }
            }
        }
        .herdrFont(.callout)
        .accessibilityIdentifier("quick-voice-capture-status")
    }
}
