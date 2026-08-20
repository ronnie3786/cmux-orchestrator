import AVFoundation
import Observation
import SwiftUI

enum HerdrVoiceRecorderStatus: Equatable {
    case idle
    case recording
    case finished
}

/// The shared record/preview engine behind both voice entry points.
///
/// Mac notes: macOS has no `AVAudioSession`, so the iOS category/activation
/// calls are gone outright — `AVAudioRecorder`/`AVAudioPlayer` drive the default
/// input/output devices directly. Microphone authorization goes through
/// `AVCaptureDevice` instead, and the sandbox needs
/// `com.apple.security.device.audio-input`. Everything else — the WAV settings,
/// the 10 minute cap, the 10 Hz metering into a 40 sample ring — is unchanged
/// from iOS on purpose: the server validates the uploaded bytes as mono 16 kHz
/// 16-bit PCM and rejects anything else.
@MainActor
@Observable
final class HerdrVoiceRecorder: NSObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    static let maxDuration: TimeInterval = 10 * 60
    private static let sampleCount = 40

    private(set) var status: HerdrVoiceRecorderStatus = .idle
    private(set) var elapsedTime: TimeInterval = 0
    private(set) var outputURL: URL?
    private(set) var samples = HerdrVoiceRecorder.baselineSamples()
    private(set) var isPlaying = false
    private(set) var playbackTime: TimeInterval = 0
    var errorMessage: String?

    // Reached from `deinit`, which is nonisolated, and never observed by a view.
    @ObservationIgnored nonisolated(unsafe) private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    @ObservationIgnored nonisolated(unsafe) private var recordingTimer: Timer?
    private var playbackTimer: Timer?
    private var startGeneration = 0

    var isRecording: Bool { status == .recording }
    var hasRecording: Bool { outputURL != nil || elapsedTime > 0 }
    var canSave: Bool { status == .finished && outputURL != nil && elapsedTime > 0 }

    var playbackProgress: Double {
        guard elapsedTime > 0 else { return 0 }
        return min(max(playbackTime / elapsedTime, 0), 1)
    }

    deinit {
        recordingTimer?.invalidate()
        if recorder?.isRecording == true {
            recorder?.stop()
        }
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func togglePlayback() {
        guard status == .finished, let outputURL else { return }
        if isPlaying {
            pausePlayback()
            return
        }

        do {
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

    func startRecording() {
        errorMessage = nil
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginCapture()
        case .denied, .restricted:
            errorMessage = "Microphone access is disabled for Herdr."
        case .notDetermined:
            let generation = startGeneration
            Task { @MainActor [weak self] in
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                guard let self, generation == self.startGeneration else { return }
                if granted {
                    self.beginCapture()
                } else {
                    self.errorMessage = "Microphone access is required to record a voice note."
                }
            }
        @unknown default:
            errorMessage = "Microphone permission is unavailable."
        }
    }

    private func beginCapture() {
        do {
            discardCurrentFile()

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

    func stopRecording() {
        let duration = recorder?.currentTime ?? elapsedTime
        recorder?.stop()
        recorder = nil
        stopRecordingTimer()
        elapsedTime = min(duration, Self.maxDuration)
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
        startGeneration += 1
        stopRecordingTimer()
        stopPlayback(reset: true)
        recorder?.stop()
        recorder = nil

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
        startGeneration += 1
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
        }
    }

}
