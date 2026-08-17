import Foundation
import Observation

@MainActor
@Observable
final class HerdrQuickVoiceCapture {
    enum Phase: Equatable {
        case idle
        case recording
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

    func beginHold() {
        guard phase == .idle else { return }
        phase = .recording
        recorder.startRecording()
    }

    func endHold(transcribe: (URL) async throws -> VoiceTranscription) async -> Outcome {
        guard phase == .recording else { return .cancelled }

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
        guard phase != .transcribing else { return }
        if phase == .recording, recorder.isRecording {
            recorder.stopRecording()
        }
        recorder.discard()
        phase = .idle
    }
}
