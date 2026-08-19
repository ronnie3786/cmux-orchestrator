import Foundation
import Observation

@MainActor
@Observable
final class HerdrQuickVoiceCapture {
    enum Phase: Equatable {
        case idle
        case recording
        case locked
        case transcribing
    }

    enum Outcome: Equatable {
        case cancelled
        case tooShort
        case transcript(VoiceTranscription)
        case failure(String)
    }

    static let minimumDuration: TimeInterval = 0.5

    private(set) var phase: Phase = .idle
    private let recorder = HerdrVoiceRecorder()
    private var lockTask: Task<Void, Never>?
    var onLock: (() -> Void)?

    var samples: [CGFloat] { recorder.samples }
    var recorderStatus: HerdrVoiceRecorderStatus { recorder.status }

    func beginHold() {
        guard phase == .idle else { return }
        phase = .recording
        recorder.startRecording()
        lockTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.65))
            guard !Task.isCancelled, let self, self.phase == .recording else { return }
            self.phase = .locked
            self.onLock?()
        }
    }

    func beginLocked() {
        guard phase == .idle else { return }
        phase = .locked
        recorder.startRecording()
        onLock?()
    }

    func endHold(transcribe: (URL) async throws -> VoiceTranscription) async -> Outcome {
        guard phase == .recording || phase == .locked else { return .cancelled }
        lockTask?.cancel()
        lockTask = nil

        if recorder.isRecording {
            recorder.stopRecording()
        }

        guard recorder.hasRecording else {
            let message = recorder.errorMessage
            recorder.discard()
            phase = .idle
            return message.map { .failure($0) } ?? .cancelled
        }

        guard recorder.elapsedTime >= Self.minimumDuration,
              recorder.canSave,
              let outputURL = recorder.outputURL
        else {
            recorder.discard()
            phase = .idle
            return .tooShort
        }

        phase = .transcribing
        do {
            let result = try await transcribe(outputURL)
            recorder.discard()
            phase = .idle
            return .transcript(result)
        } catch is CancellationError {
            recorder.discard()
            phase = .idle
            return .cancelled
        } catch {
            recorder.discard()
            phase = .idle
            return .failure(error.localizedDescription)
        }
    }

    func cancel() {
        lockTask?.cancel()
        lockTask = nil
        guard phase != .transcribing else { return }
        if (phase == .recording || phase == .locked), recorder.isRecording {
            recorder.stopRecording()
        }
        recorder.discard()
        phase = .idle
    }
}
