import SwiftUI

struct HerdrVoiceNoteRecorderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let save: (URL) -> Void
    let transcribe: (URL) async throws -> VoiceTranscription
    let insertTranscript: (VoiceTranscription) -> Void
    let cancel: () -> Void

    @State private var recorder = HerdrVoiceRecorder()
    @State private var didSave = false
    @State private var isConfirmingDiscard = false
    @State private var hapticPulse = HerdrHapticPulse()
    @State private var transcriptionRequest: UUID?
    @State private var transcriptionError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                HerdrBackground()

                ScrollView {
                    VStack(spacing: 18) {
                        recordingControl

                        HerdrVoiceWaveform(samples: recorder.samples, isRecording: recorder.isRecording)

                        VStack(spacing: 6) {
                            Text(formattedDuration(recorder.elapsedTime))
                                .font(.largeTitle.monospaced().weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(HerdrTheme.text)

                            Text(statusText)
                                .font(.footnote.monospaced().weight(.semibold))
                                .foregroundStyle(statusColor)
                                .multilineTextAlignment(.center)
                        }

                        if recorder.status == .finished {
                            playbackPreview
                        }

                        if let errorMessage = recorder.errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle")
                                .font(.footnote.monospaced())
                                .foregroundStyle(HerdrTheme.alert)
                                .multilineTextAlignment(.center)
                        }

                        if let transcriptionError {
                            Label(transcriptionError, systemImage: "waveform.badge.exclamationmark")
                                .font(.footnote.monospaced())
                                .foregroundStyle(HerdrTheme.alert)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actionButtons
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(HerdrTheme.graphite.opacity(0.98))
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(HerdrTheme.surface)
                            .frame(height: 1)
                    }
            }
            .navigationTitle("VOICE NOTE")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(HerdrTheme.graphite, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .confirmationDialog(
                "Discard voice note?",
                isPresented: $isConfirmingDiscard,
                titleVisibility: .visible
            ) {
                Button("Discard Recording", role: .destructive) {
                    discardAndClose()
                }
                Button("Keep Recording", role: .cancel) {}
            } message: {
                Text("The temporary recording will be deleted.")
            }
            .herdrHaptic(trigger: hapticPulse)
            .task(id: transcriptionRequest) {
                guard transcriptionRequest != nil,
                      recorder.canSave,
                      let outputURL = recorder.outputURL
                else { return }
                await runTranscription(outputURL)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    recorder.stopForBackground()
                }
            }
            .onChange(of: recorder.status) { oldStatus, newStatus in
                if newStatus == .recording {
                    hapticPulse.fire(.recordingStarted)
                } else if oldStatus == .recording {
                    hapticPulse.fire(.recordingStopped)
                }
            }
            .onChange(of: recorder.errorMessage) { _, message in
                if message != nil { hapticPulse.fire(.failed) }
            }
            .onDisappear {
                if !didSave {
                    recorder.discard()
                }
            }
        }
    }

    private var recordingControl: some View {
        Button {
            recorder.toggleRecording()
        } label: {
            VStack(spacing: 9) {
                Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                    .font(.title.weight(.bold))
                Text(recorder.isRecording ? "STOP" : "RECORD")
                    .font(.caption.monospaced().weight(.bold))
            }
            .foregroundStyle(recorder.isRecording ? HerdrTheme.ink : HerdrTheme.graphite)
            .frame(width: 108, height: 92)
            .background(recorder.isRecording ? HerdrTheme.alert : HerdrTheme.signal)
            .overlay {
                RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                    .strokeBorder(HerdrTheme.text.opacity(0.18), lineWidth: 1)
            }
            .clipShape(.rect(cornerRadius: HerdrTheme.cardRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")
    }

    private var playbackPreview: some View {
        HStack(spacing: 12) {
            Button {
                let wasPlaying = recorder.isPlaying
                recorder.togglePlayback()
                if wasPlaying != recorder.isPlaying {
                    hapticPulse.fire(.selection)
                }
            } label: {
                Image(systemName: recorder.isPlaying ? "pause.fill" : "play.fill")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(HerdrTheme.ink)
                    .frame(width: 44, height: 44)
                    .background(HerdrTheme.accent)
                    .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recorder.isPlaying ? "Pause preview" : "Play preview")

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("PREVIEW")
                        .font(.caption2.monospaced().weight(.bold))
                    Spacer()
                    Text("\(formattedDuration(recorder.playbackTime)) / \(formattedDuration(recorder.elapsedTime))")
                        .font(.caption2.monospaced().weight(.semibold))
                        .monospacedDigit()
                }
                .foregroundStyle(HerdrTheme.mist)

                ProgressView(value: recorder.playbackProgress)
                    .tint(HerdrTheme.accent)
            }
        }
        .padding(12)
        .background(HerdrTheme.elevated)
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(HerdrTheme.surface, lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button(role: recorder.hasRecording && !isTranscribing ? .destructive : nil) {
                hapticPulse.fire(.selection)
                if isTranscribing {
                    transcriptionRequest = nil
                } else if recorder.hasRecording {
                    isConfirmingDiscard = true
                } else {
                    closeWithoutRecording()
                }
            } label: {
                Image(systemName: isTranscribing ? "xmark" : recorder.hasRecording ? "trash" : "xmark")
                    .frame(width: 44, height: 46)
            }
            .buttonStyle(.bordered)
            .tint(recorder.hasRecording && !isTranscribing ? HerdrTheme.alert : HerdrTheme.mist)
            .accessibilityLabel(isTranscribing ? "Cancel transcription" : recorder.hasRecording ? "Discard" : "Close")

            Button {
                saveRecording()
            } label: {
                Image(systemName: "paperclip")
                    .frame(width: 44, height: 46)
            }
            .buttonStyle(.bordered)
            .tint(HerdrTheme.mist)
            .disabled(!recorder.canSave || isTranscribing)
            .accessibilityLabel("Attach audio without transcribing")

            Button {
                transcriptionError = nil
                hapticPulse.fire(.transcriptionStarted)
                transcriptionRequest = UUID()
            } label: {
                Group {
                    if isTranscribing {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Transcribing")
                        }
                    } else {
                        Label("Transcribe", systemImage: "text.bubble")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(.borderedProminent)
            .tint(HerdrTheme.accent)
            .disabled(!recorder.canSave || isTranscribing)
        }
    }

    private var isTranscribing: Bool { transcriptionRequest != nil }

    private var statusText: String {
        switch recorder.status {
        case .idle:
            "tap record · max \(formattedDuration(HerdrVoiceRecorder.maxDuration))"
        case .recording:
            "recording · tap stop when finished"
        case .finished:
            isTranscribing ? "transcribing · this may take a moment" : "ready to transcribe or attach"
        }
    }

    private var statusColor: Color {
        switch recorder.status {
        case .idle:
            HerdrTheme.mist
        case .recording:
            HerdrTheme.alert
        case .finished:
            HerdrTheme.success
        }
    }

    private func saveRecording() {
        guard recorder.canSave, let outputURL = recorder.outputURL else { return }
        didSave = true
        recorder.relinquishSavedFile()
        save(outputURL)
        dismiss()
    }

    private func runTranscription(_ outputURL: URL) async {
        do {
            let result = try await transcribe(outputURL)
            try Task.checkCancellation()
            recorder.discard()
            transcriptionRequest = nil
            insertTranscript(result)
            dismiss()
        } catch is CancellationError {
            transcriptionRequest = nil
        } catch {
            transcriptionRequest = nil
            transcriptionError = error.localizedDescription
            hapticPulse.fire(.failed)
        }
    }

    private func closeWithoutRecording() {
        recorder.discard()
        cancel()
        dismiss()
    }

    private func discardAndClose() {
        recorder.discard()
        cancel()
        dismiss()
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
