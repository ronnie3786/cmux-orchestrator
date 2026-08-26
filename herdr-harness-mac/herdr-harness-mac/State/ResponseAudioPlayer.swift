import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class ResponseAudioPlayer: NSObject, AVAudioPlayerDelegate {
    typealias Prepare = (ResponseAudioAction, String) async throws -> ResponseAudioPrepareResponse
    typealias Synthesize = (String) async throws -> ResponseAudioSpeechResponse

    private(set) var capabilities = ResponseAudioCapabilities.unavailable
    private(set) var phase: ResponseAudioPlaybackPhase = .unavailable
    private(set) var progressText: String?
    private(set) var hasPlayableResponse = false

    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var queuedAudio: [Data] = []
    @ObservationIgnored private var isPreparingMore = false
    @ObservationIgnored private var generation = 0

    var isVisible: Bool {
        hasPlayableResponse && capabilities.available && phase != .checking && phase != .unavailable
    }

    #if DEBUG
    static func preview(
        capabilities: ResponseAudioCapabilities,
        phase: ResponseAudioPlaybackPhase = .idle,
        hasPlayableResponse: Bool = true
    ) -> ResponseAudioPlayer {
        let player = ResponseAudioPlayer()
        player.capabilities = capabilities
        player.phase = phase
        player.hasPlayableResponse = hasPlayableResponse
        return player
    }
    #endif

    func loadCapabilities(
        using fetch: () async throws -> ResponseAudioCapabilities
    ) async {
        guard phase.activeAction == nil else { return }
        phase = .checking
        do {
            capabilities = try await fetch()
            phase = capabilities.available ? .idle : .unavailable
        } catch is CancellationError {
            return
        } catch {
            capabilities = .unavailable
            phase = .unavailable
        }
    }

    func activate(
        _ action: ResponseAudioAction,
        text: String,
        prepare: @escaping Prepare,
        synthesize: @escaping Synthesize,
        failure: @escaping (String) -> Void
    ) {
        guard capabilities.supports(action) else { return }
        switch phase {
        case let .preparing(activeAction) where activeAction == action:
            stop()
        case let .playing(activeAction) where activeAction == action:
            pause()
        case let .paused(activeAction) where activeAction == action:
            resume()
        default:
            begin(
                action,
                text: text,
                prepare: prepare,
                synthesize: synthesize,
                failure: failure
            )
        }
    }

    func responseDidChange(hasResponse: Bool) {
        if phase.activeAction != nil { stop() }
        hasPlayableResponse = hasResponse
    }

    func stop() {
        generation &+= 1
        renderTask?.cancel()
        renderTask = nil
        player?.stop()
        player = nil
        queuedAudio.removeAll(keepingCapacity: false)
        isPreparingMore = false
        progressText = nil
        phase = capabilities.available ? .idle : .unavailable
        deactivateAudioSession()
    }

    private func begin(
        _ action: ResponseAudioAction,
        text: String,
        prepare: @escaping Prepare,
        synthesize: @escaping Synthesize,
        failure: @escaping (String) -> Void
    ) {
        stop()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        generation &+= 1
        let expectedGeneration = generation
        phase = .preparing(action)
        progressText = action == .tldr ? "Summarizing…" : "Preparing…"
        isPreparingMore = true

        renderTask = Task { [weak self] in
            do {
                let prepared = try await prepare(action, text)
                guard !prepared.chunks.isEmpty else { throw ResponseAudioPlaybackError.emptyAudio }

                for (index, chunk) in prepared.chunks.enumerated() {
                    try Task.checkCancellation()
                    guard let self, expectedGeneration == self.generation else { return }
                    self.progressText = "Preparing \(index + 1)/\(prepared.chunks.count)…"
                    let response = try await synthesize(chunk)
                    guard let data = Data(base64Encoded: response.audioBase64), !data.isEmpty else {
                        throw ResponseAudioPlaybackError.invalidAudio
                    }
                    guard expectedGeneration == self.generation else { return }
                    try self.enqueue(data, action: action)
                }

                guard let self, expectedGeneration == self.generation else { return }
                self.isPreparingMore = false
                self.progressText = nil
                if self.player == nil, self.queuedAudio.isEmpty {
                    self.finishPlayback()
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, expectedGeneration == self.generation else { return }
                let message = error.localizedDescription
                self.stop()
                failure(message)
            }
        }
    }

    private func enqueue(_ data: Data, action: ResponseAudioAction) throws {
        queuedAudio.append(data)
        if player == nil {
            try playNext(action: action)
        }
    }

    private func playNext(action: ResponseAudioAction) throws {
        guard !queuedAudio.isEmpty else {
            if !isPreparingMore { finishPlayback() }
            return
        }
        try activateAudioSession()
        let next = queuedAudio.removeFirst()
        let player = try AVAudioPlayer(data: next)
        player.delegate = self
        player.prepareToPlay()
        guard player.play() else { throw ResponseAudioPlaybackError.invalidAudio }
        self.player = player
        phase = .playing(action)
    }

    private func pause() {
        guard case let .playing(action) = phase, let player else { return }
        player.pause()
        phase = .paused(action)
        progressText = nil
    }

    private func resume() {
        guard case let .paused(action) = phase else { return }
        do {
            if let player {
                try activateAudioSession()
                guard player.play() else { throw ResponseAudioPlaybackError.invalidAudio }
                phase = .playing(action)
            } else {
                try playNext(action: action)
            }
        } catch {
            stop()
        }
    }

    private func finishPlayback() {
        player = nil
        queuedAudio.removeAll(keepingCapacity: false)
        progressText = nil
        phase = capabilities.available ? .idle : .unavailable
        deactivateAudioSession()
    }

    private func activateAudioSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        #endif
    }

    private func deactivateAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finishedPlayer = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self,
                  let current = self.player,
                  ObjectIdentifier(current) == finishedPlayer,
                  let action = self.phase.activeAction
            else { return }
            self.player = nil
            do {
                try self.playNext(action: action)
            } catch {
                self.stop()
            }
        }
    }
}

private enum ResponseAudioPlaybackError: LocalizedError {
    case emptyAudio
    case invalidAudio

    var errorDescription: String? {
        switch self {
        case .emptyAudio: "The response did not contain readable text."
        case .invalidAudio: "The audio service returned an invalid recording."
        }
    }
}
