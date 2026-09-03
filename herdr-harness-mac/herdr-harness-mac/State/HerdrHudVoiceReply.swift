import AppKit
import Foundation
import Observation

/// The seam the voice reply talks to the app model through, so the state
/// machine can be driven by a fake in tests. Mirrors the shape of
/// `HerdrNoteAIRunner` / `HerdrNoteSessionSpawner`.
@MainActor
protocol HerdrHudVoiceReplyGateway: AnyObject {
    func transcribe(_ url: URL) async throws -> VoiceTranscription
    func pane(id: String) -> HerdrPane?
    func sendPrompt(_ text: String, to pane: HerdrPane) async throws
    func acknowledgeUnreadAlerts(for pane: HerdrPane)
    func dismissHudChip(_ paneID: String)
}

@MainActor
final class HerdrLiveVoiceReplyGateway: HerdrHudVoiceReplyGateway {
    private let model: HerdrAppModel

    init(model: HerdrAppModel) {
        self.model = model
    }

    func transcribe(_ url: URL) async throws -> VoiceTranscription {
        try await model.transcribeVoiceNote(at: url)
    }

    func pane(id: String) -> HerdrPane? {
        model.pane(id: id)
    }

    /// The harness can answer 5xx/409 while pi is still attaching to a pane, so
    /// this mirrors the notes spawner's bounded retry rather than failing the
    /// first attempt.
    func sendPrompt(_ text: String, to pane: HerdrPane) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(25))
        while true {
            try Task.checkCancellation()
            do {
                try await model.sendPiConversationPrompt(text, disposition: .prompt, to: pane)
                return
            } catch {
                guard Self.isRetryable(error), clock.now < deadline else { throw error }
                try await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func acknowledgeUnreadAlerts(for pane: HerdrPane) {
        model.acknowledgeUnreadAlerts(for: pane)
    }

    func dismissHudChip(_ paneID: String) {
        model.dismissHudChip(paneID)
    }

    private static func isRetryable(_ error: any Error) -> Bool {
        if let apiError = error as? APIError, case let .server(status, _) = apiError {
            return status >= 500 || status == 409
        }
        if let urlError = error as? URLError { return urlError.code != .cancelled }
        return false
    }
}

/// Record → transcribe → edit → send, for replying by voice to the agent whose
/// answer the HUD just read aloud.
@MainActor
@Observable
final class HerdrHudVoiceReply {
    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case editing
        case sending
        case sent
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var paneID: String?
    private(set) var usedFallback = false
    /// The transcript, editable before it is sent.
    var draft = ""

    @ObservationIgnored private let capture: HerdrQuickVoiceCapture
    @ObservationIgnored private let dismissDelay: Duration
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    var samples: [CGFloat] { capture.samples }
    var isBusy: Bool { phase == .transcribing || phase == .sending }
    var canSend: Bool {
        phase == .editing && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(
        capture: HerdrQuickVoiceCapture = HerdrQuickVoiceCapture(),
        dismissDelay: Duration = .milliseconds(1_500)
    ) {
        self.capture = capture
        self.dismissDelay = dismissDelay
    }

    /// Points the reply at a pi session. Retargeting mid-flight would send the
    /// recording to the wrong agent, so an in-progress reply wins.
    func target(paneID: String) {
        guard self.paneID != paneID else { return }
        guard phase == .idle || phase == .sent else { return }
        dismissTask?.cancel()
        dismissTask = nil
        self.paneID = paneID
        draft = ""
        usedFallback = false
        phase = .idle
    }

    /// Also the retry path: a failed attempt re-enters recording cleanly.
    func start() {
        guard paneID != nil else { return }
        switch phase {
        case .idle, .failed:
            capture.cancel()
            beginRecording()
        case .recording, .transcribing, .editing, .sending, .sent:
            break
        }
    }

    private func beginRecording() {
        dismissTask?.cancel()
        dismissTask = nil
        draft = ""
        usedFallback = false
        phase = .recording
        capture.beginLocked()
    }

    func stopAndTranscribe(gateway: some HerdrHudVoiceReplyGateway) async {
        guard phase == .recording else { return }
        phase = .transcribing
        let outcome = await capture.endHold { url in
            try await gateway.transcribe(url)
        }
        switch outcome {
        case .cancelled:
            phase = .idle
        case .tooShort:
            phase = .failed("Hold the mic a little longer.")
        case let .failure(message):
            phase = .failed(message)
        case let .transcript(transcript):
            let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                phase = .failed("Nothing was picked up.")
                return
            }
            draft = text
            usedFallback = transcript.usedFallback
            phase = .editing
        }
    }

    func send(gateway: some HerdrHudVoiceReplyGateway) async {
        guard canSend, let paneID else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pane = gateway.pane(id: paneID) else {
            phase = .failed("That session is no longer available.")
            return
        }
        phase = .sending
        do {
            try await gateway.sendPrompt(text, to: pane)
        } catch {
            // Keep the draft so the user can retry, and make sure the words are
            // not lost even if the session never comes back.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            phase = .failed("Couldn't send. Copied to the clipboard instead.")
            return
        }
        // Replying is the strongest possible "I've seen this". The alert ack and
        // the HUD chip are separate state machines and neither cascades.
        gateway.acknowledgeUnreadAlerts(for: pane)
        gateway.dismissHudChip(paneID)
        draft = ""
        phase = .sent
        let delay = dismissDelay
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.phase == .sent else { return }
            self.reset()
        }
    }

    #if DEBUG
    /// Recording needs a real microphone, so tests jump straight to the state a
    /// finished transcription would leave behind.
    func enterEditingForTesting(transcript: String, usedFallback: Bool = false) {
        draft = transcript
        self.usedFallback = usedFallback
        phase = .editing
    }
    #endif

    func cancel() {
        capture.cancel()
        reset()
    }

    func reset() {
        dismissTask?.cancel()
        dismissTask = nil
        draft = ""
        usedFallback = false
        paneID = nil
        phase = .idle
    }
}
