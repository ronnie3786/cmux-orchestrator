import AVFoundation
import Foundation

enum VoiceNoteRecorderStatus: Equatable {
    case idle
    case recording
    case finished
}

@MainActor
final class VoiceNoteRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    static let maxDuration: TimeInterval = 10 * 60

    @Published var status: VoiceNoteRecorderStatus = .idle
    @Published var elapsedTime: TimeInterval = 0
    @Published var errorMessage: String?
    @Published var outputURL: URL?
    @Published var isPlaying = false
    @Published var playbackTime: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var recordingTimer: Timer?
    private var playbackTimer: Timer?

    var isRecording: Bool { status == .recording }
    var hasStartedRecording: Bool { status == .recording || outputURL != nil || elapsedTime > 0 }
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
            let player = try self.player ?? AVAudioPlayer(contentsOf: outputURL)
            player.delegate = self
            player.prepareToPlay()
            if player.duration > 0, player.currentTime >= player.duration {
                player.currentTime = 0
            }
            self.player = player
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

    private func requestPermissionAndStart() {
        errorMessage = nil
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startRecording()
        case .denied, .restricted:
            errorMessage = "Microphone access is disabled for cmux Harness."
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    granted ? self.startRecording() : (self.errorMessage = "Microphone access is required to record voice notes.")
                }
            }
        @unknown default:
            errorMessage = "Microphone permission is unavailable."
        }
    }

    private func startRecording() {
        do {
            discardCurrentFile()
            let url = Self.makeVoiceNoteURL()
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
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
        status = outputURL == nil ? .idle : .finished
    }

    private func cleanup(deleteFile: Bool) {
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
        if recorder.currentTime >= Self.maxDuration {
            stopRecording()
        }
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

    private static func makeVoiceNoteURL() -> URL {
        let filename = "cmux-voice-note-\(Int(Date().timeIntervalSince1970)).m4a"
        return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            self.recorder = nil
            elapsedTime = min(max(elapsedTime, recorder.currentTime), Self.maxDuration)
            stopRecordingTimer()
            status = flag ? .finished : .idle
            if !flag {
                errorMessage = "Recording could not be saved."
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            playbackTime = elapsedTime
            isPlaying = false
            stopPlaybackTimer()
        }
    }

}
