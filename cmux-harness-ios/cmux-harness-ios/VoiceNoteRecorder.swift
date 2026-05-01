import AVFoundation
import Combine
import ComposableArchitecture
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum VoiceNoteRecorderStatus: Equatable {
    case idle
    case recording
    case finished
}

@MainActor
final class VoiceNoteRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    static let maxDuration: TimeInterval = 10 * 60
    private static let waveformSampleCount = 44

    @Published var status: VoiceNoteRecorderStatus = .idle
    @Published var elapsedTime: TimeInterval = 0
    @Published var errorMessage: String?
    @Published var outputURL: URL?
    @Published var levelSamples: [CGFloat] = VoiceNoteRecorder.baselineSamples()
    @Published var isPlaying = false
    @Published var playbackTime: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var recordingTimer: Timer?
    private var playbackTimer: Timer?

    var isRecording: Bool {
        status == .recording
    }

    var hasStartedRecording: Bool {
        status == .recording || outputURL != nil || elapsedTime > 0
    }

    var canSave: Bool {
        status == .finished && outputURL != nil && elapsedTime > 0
    }

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
            if let existingPlayer = self.player {
                player = existingPlayer
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

    func discard() {
        cleanup(deleteFile: true)
    }

    func resetAfterSaving() {
        cleanup(deleteFile: false)
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
        levelSamples = Self.baselineSamples()
        status = .idle
    }

    private func requestPermissionAndStart() {
        errorMessage = nil
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            startRecording()
        case .denied:
            errorMessage = "Microphone access is disabled for cmux harness."
        case .undetermined:
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if granted {
                        self.startRecording()
                    } else {
                        self.errorMessage = "Microphone access is required to record voice notes."
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

            let url = Self.makeVoiceNoteURL()
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            recorder.prepareToRecord()
            recorder.record(forDuration: Self.maxDuration)

            self.recorder = recorder
            outputURL = url
            elapsedTime = 0
            playbackTime = 0
            levelSamples = Self.baselineSamples()
            status = .recording
            startRecordingTimer()
        } catch {
            errorMessage = error.localizedDescription
            cleanup(deleteFile: true)
        }
    }

    private func stopRecording() {
        let finalDuration = recorder?.currentTime ?? elapsedTime
        recorder?.stop()
        recorder = nil
        stopRecordingTimer()
        elapsedTime = min(finalDuration, Self.maxDuration)
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
        appendLevelSample(Self.normalizedLevel(fromPower: recorder.averagePower(forChannel: 0)))
        if recorder.currentTime >= Self.maxDuration {
            stopRecording()
        }
    }

    private func appendLevelSample(_ sample: CGFloat) {
        var samples = levelSamples
        samples.append(sample)
        if samples.count > Self.waveformSampleCount {
            samples.removeFirst(samples.count - Self.waveformSampleCount)
        }
        levelSamples = samples
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
        levelSamples = Self.baselineSamples()
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
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

    private static func baselineSamples() -> [CGFloat] {
        Array(repeating: 0.08, count: waveformSampleCount)
    }

    private static func normalizedLevel(fromPower power: Float) -> CGFloat {
        let clamped = min(max(power, -50), 0)
        let linear = pow(10, Double(clamped) / 35)
        return CGFloat(min(max(linear, 0.08), 1))
    }

    private static func makeVoiceNoteURL() -> URL {
        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "voice-note-\(timestamp)-\(UUID().uuidString.prefix(8)).m4a"
        return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            stopRecordingTimer()
            self.recorder = nil
            elapsedTime = min(Swift.max(elapsedTime, recorder.currentTime), Self.maxDuration)
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

    deinit {
        recordingTimer?.invalidate()
        playbackTimer?.invalidate()
        recorder?.stop()
        player?.stop()
    }
}

struct VoiceNoteRecorderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = VoiceNoteRecorder()
    @State private var didSave = false
    @State private var isShowingDiscardConfirmation = false

    let saveAction: (URL) -> Void
    let discardAction: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Spacer(minLength: 4)

                recordingButton

                VoiceWaveformView(
                    samples: recorder.levelSamples,
                    isRecording: recorder.isRecording
                )

                VStack(spacing: 8) {
                    Text(durationText)
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)

                    Text(statusText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .multilineTextAlignment(.center)
                }

                if recorder.status == .finished {
                    playbackPreview
                }

                if let errorMessage = recorder.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18)
                }

                Spacer(minLength: 4)

                HStack(spacing: 12) {
                    Button(role: recorder.hasStartedRecording ? .destructive : nil) {
                        HarnessHaptics.inputCTA()
                        if recorder.hasStartedRecording {
                            isShowingDiscardConfirmation = true
                        } else {
                            closeWithoutRecording()
                        }
                    } label: {
                        Label(recorder.hasStartedRecording ? "Discard" : "Close", systemImage: recorder.hasStartedRecording ? "trash" : "xmark")
                            .frame(maxWidth: .infinity, minHeight: 46)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        HarnessHaptics.sendCTA()
                        saveRecording()
                    } label: {
                        Label("Save", systemImage: "checkmark")
                            .frame(maxWidth: .infinity, minHeight: 46)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!recorder.canSave)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .navigationTitle("Voice Note")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Discard voice note?", isPresented: $isShowingDiscardConfirmation, titleVisibility: .visible) {
                Button("Discard Recording", role: .destructive) {
                    HarnessHaptics.inputCTA()
                    discardRecording()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will delete the current voice note.")
            }
            .onDisappear {
                if !didSave {
                    recorder.discard()
                }
            }
        }
    }

    private var recordingButton: some View {
        Button {
            HarnessHaptics.inputCTA()
            recorder.toggleRecording()
        } label: {
            ZStack {
                Circle()
                    .fill(recorder.isRecording ? Color.red : Color.accentColor)
                    .frame(width: 96, height: 96)
                    .shadow(color: (recorder.isRecording ? Color.red : Color.accentColor).opacity(0.35), radius: 18, y: 8)

                Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")
    }

    private var durationText: String {
        formattedDuration(recorder.elapsedTime)
    }

    private var statusText: String {
        switch recorder.status {
        case .idle:
            return "Tap the microphone to start. Limit \(formattedDuration(VoiceNoteRecorder.maxDuration))."
        case .recording:
            return "Recording. Stops at \(formattedDuration(VoiceNoteRecorder.maxDuration))."
        case .finished:
            return "Ready to attach."
        }
    }

    private var statusColor: Color {
        switch recorder.status {
        case .recording:
            return .red
        case .finished:
            return .green
        case .idle:
            return .secondary
        }
    }

    private var playbackPreview: some View {
        HStack(spacing: 12) {
            Button {
                HarnessHaptics.inputCTA()
                recorder.togglePlayback()
            } label: {
                Image(systemName: recorder.isPlaying ? "pause.fill" : "play.fill")
                    .font(.headline.weight(.bold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(Color.accentColor, in: Circle())
            .accessibilityLabel(recorder.isPlaying ? "Pause preview" : "Play preview")

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Preview")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text("\(formattedDuration(recorder.playbackTime)) / \(durationText)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: recorder.playbackProgress)
                    .tint(Color.accentColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func saveRecording() {
        guard let url = recorder.outputURL, recorder.canSave else { return }
        didSave = true
        recorder.resetAfterSaving()
        saveAction(url)
        dismiss()
    }

    private func closeWithoutRecording() {
        didSave = false
        recorder.discard()
        discardAction()
        dismiss()
    }

    private func discardRecording() {
        didSave = false
        recorder.discard()
        discardAction()
        dismiss()
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

struct VoiceWaveformView: View {
    let samples: [CGFloat]
    let isRecording: Bool

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 3
            let barWidth = max(2, (geometry.size.width - spacing * CGFloat(max(samples.count - 1, 0))) / CGFloat(max(samples.count, 1)))

            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(barColor(index: index))
                        .frame(width: barWidth, height: max(4, geometry.size.height * min(max(sample, 0.08), 1)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 52)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .animation(.linear(duration: 0.08), value: samples)
    }

    private func barColor(index: Int) -> Color {
        let base = isRecording ? Color.red : Color.accentColor
        guard samples.count > 1 else { return base.opacity(0.62) }
        let recency = Double(index) / Double(samples.count - 1)
        return base.opacity(isRecording ? 0.28 + recency * 0.62 : 0.42)
    }
}
