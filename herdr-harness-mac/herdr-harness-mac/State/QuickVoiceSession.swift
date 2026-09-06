import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class QuickVoiceSession: NSObject, AVAudioPlayerDelegate {
    enum Phase: Equatable { case idle, recording, transcribing, submitting }
    struct Note: Identifiable, Equatable {
        let machineID: String
        let job: QuickVoiceJob
        var id: String { machineID + ":" + job.id }
    }
    struct Pending: Codable {
        let machineID: String
        let request: QuickVoiceRequest
    }

    private(set) var phase: Phase = .idle
    private(set) var notes: [Note] = []
    private(set) var selectedNoteID: String? {
        didSet { defaults.set(selectedNoteID, forKey: "herdr.quickVoice.selectedNote") }
    }
    private(set) var transcript = ""
    private(set) var error: String?
    private(set) var connectionError: String?
    private(set) var playingMessageID: String?
    var machineID = "" {
        didSet { defaults.set(machineID, forKey: "herdr.quickVoice.machine") }
    }
    var isMuted = false {
        didSet {
            defaults.set(isMuted, forKey: "herdr.quickVoice.muted")
            if isMuted { stopAudio() }
        }
    }
    let recorder = HerdrVoiceRecorder()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private weak var model: HerdrAppModel?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var captureTask: Task<Void, Never>?
    @ObservationIgnored private var audioTask: Task<Void, Never>?
    @ObservationIgnored private var audioPlayer: AVAudioPlayer?
    @ObservationIgnored private var played: Set<String>
    @ObservationIgnored private var pending: Pending?
    @ObservationIgnored private var captureMachineID = ""
    @ObservationIgnored private var captureCWD: String?
    @ObservationIgnored private var audioGeneration = 0
    @ObservationIgnored private var refreshGeneration = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        played = Set(defaults.stringArray(forKey: "herdr.quickVoice.played") ?? [])
        if let data = defaults.data(forKey: "herdr.quickVoice.pending") {
            pending = try? JSONDecoder().decode(Pending.self, from: data)
        }
        super.init()
        machineID = defaults.string(forKey: "herdr.quickVoice.machine") ?? ""
        isMuted = defaults.bool(forKey: "herdr.quickVoice.muted")
        selectedNoteID = defaults.string(forKey: "herdr.quickVoice.selectedNote")
        if let pending {
            transcript = pending.request.text
            error = "A voice note has an unconfirmed submission. Retry to recover it without creating duplicate chats."
        }
    }

    var hasPendingSubmission: Bool { pending != nil }
    var selectedNote: Note? {
        guard phase == .idle, pending == nil else { return nil }
        return notes.first { $0.id == selectedNoteID }
    }
    var machineName: String { model?.machines.first { $0.id == machineID }?.name ?? "Choose a Mac" }
    var activeCount: Int { notes.filter { !$0.job.isFinished }.count }
    var contextFolder: String {
        let pane = model?.pane(id: model?.selectedPaneID)
        guard pane?.machineID == machineID, let cwd = pane?.foregroundCWD ?? pane?.cwd, !cwd.isEmpty else { return "Home folder" }
        return cwd
    }
    var canCapture: Bool { phase == .idle && pending == nil && model?.canControl(machineID: machineID) == true && model?.isDemoMode == false }

    func configure(model: HerdrAppModel) {
        guard self.model == nil else { return }
        self.model = model
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: .seconds(self.activeCount > 0 ? 2 : 8))
            }
        }
    }

    func refresh() async {
        guard let model else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        let live = model.machines.filter { model.canControl(machineID: $0.id) && !model.isDemoMode }
        if machineID.isEmpty { machineID = live.first?.id ?? "" }
        var selectedFailure: String?
        for machine in live {
            do {
                let response = try await model.quickVoiceClient(machineID: machine.id).fetchQuickVoiceNotes()
                guard generation == refreshGeneration else { return }
                guard response.ok else { throw APIError.invalidResponse }
                notes.removeAll { $0.machineID == machine.id }
                notes += response.jobs.map { Note(machineID: machine.id, job: $0) }
            } catch {
                guard generation == refreshGeneration else { return }
                if machine.id == machineID {
                    selectedFailure = "Can't refresh voice requests on \(machine.name). Check the connection or choose another Mac."
                }
            }
        }
        notes.removeAll { note in !model.machines.contains { $0.id == note.machineID } }
        notes.sort { $0.job.createdAt > $1.job.createdAt }
        connectionError = selectedFailure
        playNextAutomaticMessage()
    }

    func toggleCapture() {
        if phase == .recording { finishCapture(); return }
        guard canCapture else { return }
        stopAudio()
        error = nil
        transcript = ""
        selectedNoteID = nil
        captureMachineID = machineID
        let pane = model?.pane(id: model?.selectedPaneID)
        let cwd = pane?.machineID == machineID ? pane?.foregroundCWD ?? pane?.cwd : nil
        captureCWD = cwd?.isEmpty == false ? cwd : nil
        phase = .recording
        recorder.startRecording()
        recordingStateChanged()
    }

    func recordingStateChanged() {
        guard phase == .recording else { return }
        if let message = recorder.errorMessage {
            error = message
            recorder.discard()
            phase = .idle
        } else if recorder.status == .finished {
            finishCapture()
        }
    }

    func cancelRecording() {
        guard phase == .recording else { return }
        phase = .idle
        recorder.discard()
    }

    func finishCapture() {
        guard phase == .recording, let model else { return }
        phase = .transcribing
        if recorder.isRecording { recorder.stopRecording() }
        guard recorder.canSave, recorder.elapsedTime >= 0.5, let url = recorder.outputURL else {
            error = recorder.errorMessage ?? "Record at least half a second, then click Stop and send."
            recorder.discard()
            phase = .idle
            return
        }
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await model.transcribeQuickVoice(at: url, machineID: captureMachineID)
                recorder.discard()
                transcript = text
                pending = Pending(machineID: captureMachineID, request: QuickVoiceRequest(requestId: UUID().uuidString, text: text, cwd: captureCWD))
                defaults.set(try JSONEncoder().encode(pending), forKey: "herdr.quickVoice.pending")
                await submitPending()
            } catch {
                // Keep the recording for a transcription retry instead of losing the note.
                self.error = "Transcription failed. \(error.localizedDescription)"
                phase = .idle
            }
        }
    }

    func retry() {
        error = nil
        if pending != nil {
            phase = .submitting
            captureTask = Task { await submitPending() }
        } else if recorder.canSave {
            phase = .recording
            finishCapture()
        }
    }

    private func submitPending() async {
        guard let pending, let model else { phase = .idle; return }
        phase = .submitting
        defer { phase = .idle }
        do {
            let response = try await model.quickVoiceClient(machineID: pending.machineID).submitQuickVoice(pending.request)
            guard response.ok else { throw APIError.invalidResponse }
            refreshGeneration += 1
            notes.removeAll { $0.machineID == pending.machineID && $0.job.id == response.job.id }
            notes.insert(Note(machineID: pending.machineID, job: response.job), at: 0)
            selectedNoteID = pending.machineID + ":" + response.job.id
            self.pending = nil
            defaults.removeObject(forKey: "herdr.quickVoice.pending")
            error = nil
            // Deliver the acknowledgment promptly instead of waiting for an
            // idle eight-second poll. Agent state arrives independently.
            Task { await refresh() }
        } catch {
            self.error = "Submission isn’t confirmed. Retry uses the same request ID to avoid duplicate chats. \(error.localizedDescription)"
        }
    }

    func dismissError() {
        // Unconfirmed submissions must be recovered, never silently resubmitted with a fresh ID.
        guard pending == nil else { return }
        error = nil
        recorder.discard()
    }

    func clearPendingNote() {
        guard phase == .idle else { return }
        pending = nil
        defaults.removeObject(forKey: "herdr.quickVoice.pending")
        transcript = ""
        error = nil
    }

    func selectNote(_ id: String) {
        guard phase == .idle, pending == nil else { return }
        selectedNoteID = id
        error = nil
    }

    func openAgent(_ task: QuickVoiceJob.Quest, in note: Note) {
        guard let paneID = task.paneID, let model else { return }
        let scopedID = MachineScopedID.compose(machineID: note.machineID, rawID: paneID)
        Task {
            if model.pane(id: scopedID) == nil { await model.refresh() }
            HerdrMacAppDelegate.openPaneURLWithFallback(scopedID)
        }
    }

    #if DEBUG
    func seedForTesting(notes: [Note], selectedNoteID: String? = nil, phase: Phase = .idle) {
        self.notes = notes
        self.selectedNoteID = selectedNoteID
        self.phase = phase
    }
    #endif

    private func playNextAutomaticMessage() {
        guard !isMuted, phase == .idle, audioTask == nil, playingMessageID == nil else { return }
        for note in notes.reversed() {
            // Do not read a backlog of old reports aloud on a fresh installation.
            guard Date().timeIntervalSince1970 - note.job.createdAt < 24 * 60 * 60 else { continue }
            for message in note.job.messages {
                let id = messageKey(note, message)
                guard !played.contains(id) else { continue }
                if message.audioStatus == "preparing" { break }
                if message.audioStatus == "failed" { rememberPlayed(id); continue }
                play(note: note, message: message)
                return
            }
        }
    }

    func play(note: Note, message: QuickVoiceJob.Message) {
        guard phase != .recording, phase != .transcribing, message.audioStatus == "ready", let model else { return }
        stopAudio()
        let id = messageKey(note, message)
        let generation = audioGeneration
        playingMessageID = id
        audioTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == audioGeneration { audioTask = nil } }
            do {
                let response = try await model.quickVoiceClient(machineID: note.machineID).fetchQuickVoiceAudio(jobID: note.job.id, messageID: message.id)
                guard generation == audioGeneration else { return }
                guard let data = Data(base64Encoded: response.audioBase64) else { throw APIError.invalidResponse }
                let player = try AVAudioPlayer(data: data)
                player.delegate = self
                guard player.play() else { throw APIError.invalidResponse }
                audioPlayer = player
                rememberPlayed(id)
            } catch {
                guard generation == audioGeneration else { return }
                playingMessageID = nil
                rememberPlayed(id)
                self.error = "Couldn’t play this audio message. Its text is available below; use Replay to try again."
            }
        }
    }

    func stopAudio() {
        audioGeneration += 1
        audioTask?.cancel()
        audioTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        playingMessageID = nil
    }

    private func messageKey(_ note: Note, _ message: QuickVoiceJob.Message) -> String { note.id + ":" + message.id }
    private func rememberPlayed(_ id: String) {
        played.insert(id)
        defaults.set(Array(played).sorted(), forKey: "herdr.quickVoice.played")
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let current = audioPlayer, ObjectIdentifier(current) == identity else { return }
            audioPlayer = nil
            playingMessageID = nil
            playNextAutomaticMessage()
        }
    }
}
