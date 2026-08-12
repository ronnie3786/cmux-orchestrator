import AVFoundation
import Observation
import SwiftUI

private enum HerdrVoiceRecorderStatus: Equatable {
    case idle
    case recording
    case finished
}

@MainActor
@Observable
private final class HerdrVoiceRecorder: NSObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    static let maxDuration: TimeInterval = 10 * 60
    private static let sampleCount = 40

    private(set) var status: HerdrVoiceRecorderStatus = .idle
    private(set) var elapsedTime: TimeInterval = 0
    private(set) var outputURL: URL?
    private(set) var samples = HerdrVoiceRecorder.baselineSamples()
    private(set) var isPlaying = false
    private(set) var playbackTime: TimeInterval = 0
    var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var recordingTimer: Timer?
    private var playbackTimer: Timer?

    var isRecording: Bool { status == .recording }
    var hasRecording: Bool { outputURL != nil || elapsedTime > 0 }
    var canSave: Bool { status == .finished && outputURL != nil && elapsedTime > 0 }

    var playbackProgress: Double {
        guard elapsedTime > 0 else { return 0 }
        return min(max(playbackTime / elapsedTime, 0), 1)
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            requestPermissionAndStart()
        }
    }

    func togglePlayback() {
        guard status == .finished, let outputURL else { return }
        if isPlaying {
            pausePlayback()
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)

            let player: AVAudioPlayer
            if let current = self.player {
                player = current
            } else {
                player = try AVAudioPlayer(contentsOf: outputURL)
                player.delegate = self
                player.prepareToPlay()
                self.player = player
            }

            if player.duration > 0, player.currentTime >= player.duration {
                player.currentTime = 0
            }
            playbackTime = player.currentTime
            player.play()
            isPlaying = true
            startPlaybackTimer()
        } catch {
            errorMessage = error.localizedDescription
            isPlaying = false
            stopPlaybackTimer()
        }
    }

    func stopForBackground() {
        if isRecording {
            stopRecording()
        }
        if isPlaying {
            pausePlayback()
        }
    }

    func discard() {
        cleanup(deleteFile: true)
    }

    /// Relinquishes ownership of the temporary file so the uploader can read it
    /// after this sheet disappears.
    func relinquishSavedFile() {
        cleanup(deleteFile: false)
    }

    private func requestPermissionAndStart() {
        errorMessage = nil
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            startRecording()
        case .denied:
            errorMessage = "Microphone access is disabled for Herdr."
        case .undetermined:
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if granted {
                        self.startRecording()
                    } else {
                        self.errorMessage = "Microphone access is required to record a voice note."
                    }
                }
            }
        @unknown default:
            errorMessage = "Microphone permission is unavailable."
        }
    }

    private func startRecording() {
        do {
            discardCurrentFile()

            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
            try session.setActive(true)

            let outputURL = VoiceRecordingPolicy.makeTemporaryURL()
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let recorder = try AVAudioRecorder(url: outputURL, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            recorder.prepareToRecord()
            try VoiceRecordingPolicy.applyCompleteProtection(to: outputURL)
            recorder.record(forDuration: Self.maxDuration)

            self.recorder = recorder
            self.outputURL = outputURL
            elapsedTime = 0
            playbackTime = 0
            samples = Self.baselineSamples()
            status = .recording
            startRecordingTimer()
        } catch {
            cleanup(deleteFile: true)
            errorMessage = error.localizedDescription
        }
    }

    private func stopRecording() {
        let duration = recorder?.currentTime ?? elapsedTime
        recorder?.stop()
        recorder = nil
        stopRecordingTimer()
        elapsedTime = min(duration, Self.maxDuration)
        deactivateAudioSession()
        status = outputURL == nil ? .idle : .finished
    }

    private func startRecordingTimer() {
        stopRecordingTimer()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recordingTimerTick()
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        if let recorder {
            elapsedTime = recorder.currentTime
        }
    }

    private func recordingTimerTick() {
        guard let recorder else { return }
        recorder.updateMeters()
        elapsedTime = min(recorder.currentTime, Self.maxDuration)

        var updatedSamples = samples
        updatedSamples.append(Self.normalizedLevel(fromPower: recorder.averagePower(forChannel: 0)))
        if updatedSamples.count > Self.sampleCount {
            updatedSamples.removeFirst(updatedSamples.count - Self.sampleCount)
        }
        samples = updatedSamples

        if recorder.currentTime >= Self.maxDuration {
            stopRecording()
        }
    }

    private func cleanup(deleteFile: Bool) {
        stopRecordingTimer()
        stopPlayback(reset: true)
        recorder?.stop()
        recorder = nil
        deactivateAudioSession()

        if deleteFile, let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        outputURL = nil
        elapsedTime = 0
        playbackTime = 0
        errorMessage = nil
        samples = Self.baselineSamples()
        status = .idle
    }

    private func discardCurrentFile() {
        stopRecordingTimer()
        stopPlayback(reset: true)
        recorder?.stop()
        recorder = nil
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        outputURL = nil
        elapsedTime = 0
        playbackTime = 0
        samples = Self.baselineSamples()
    }

    private func pausePlayback() {
        player?.pause()
        playbackTime = player?.currentTime ?? playbackTime
        isPlaying = false
        stopPlaybackTimer()
    }

    private func stopPlayback(reset: Bool) {
        stopPlaybackTimer()
        player?.stop()
        if reset {
            player?.currentTime = 0
            player = nil
            playbackTime = 0
        } else {
            playbackTime = player?.currentTime ?? playbackTime
        }
        isPlaying = false
    }

    private func startPlaybackTimer() {
        stopPlaybackTimer()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player else { return }
                self.playbackTime = player.currentTime
                if !player.isPlaying {
                    self.isPlaying = false
                    self.stopPlaybackTimer()
                }
            }
        }
    }

    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private static func baselineSamples() -> [CGFloat] {
        Array(repeating: 0.08, count: sampleCount)
    }

    private static func normalizedLevel(fromPower power: Float) -> CGFloat {
        let clamped = min(max(power, -50), 0)
        let linear = pow(10, Double(clamped) / 35)
        return CGFloat(min(max(linear, 0.08), 1))
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            stopRecordingTimer()
            self.recorder = nil
            elapsedTime = min(max(elapsedTime, recorder.currentTime), Self.maxDuration)
            deactivateAudioSession()
            status = flag && outputURL != nil ? .finished : .idle
            if !flag {
                errorMessage = "Recording failed."
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            stopPlaybackTimer()
            self.player?.currentTime = 0
            playbackTime = 0
            isPlaying = false
            deactivateAudioSession()
        }
    }

}

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

private struct HerdrVoiceWaveform: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let samples: [CGFloat]
    let isRecording: Bool

    var body: some View {
        GeometryReader { geometry in
            let spacing = 3.0
            let barCount = CGFloat(max(samples.count, 1))
            let totalSpacing = spacing * CGFloat(max(samples.count - 1, 0))
            let barWidth = max(2, (geometry.size.width - totalSpacing) / barCount)

            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor(index: index))
                        .frame(
                            width: barWidth,
                            height: max(4, geometry.size.height * min(max(sample, 0.08), 1))
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 52)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(HerdrTheme.elevated)
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(HerdrTheme.surface, lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
        .animation(reduceMotion ? nil : .linear(duration: 0.08), value: samples)
        .accessibilityHidden(true)
    }

    private func barColor(index: Int) -> Color {
        let baseColor = isRecording ? HerdrTheme.alert : HerdrTheme.accent
        guard samples.count > 1 else { return baseColor.opacity(0.62) }
        let recency = Double(index) / Double(samples.count - 1)
        return baseColor.opacity(isRecording ? 0.30 + recency * 0.65 : 0.45)
    }
}
