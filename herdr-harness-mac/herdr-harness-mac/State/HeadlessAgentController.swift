import Foundation
import Observation

@MainActor
@Observable
final class HeadlessAgentController {
    private(set) var run: HeadlessAgentRun?
    private(set) var machineID: String?
    private(set) var isSubmitting = false
    private(set) var isPromoting = false
    private(set) var errorMessage: String?

    @ObservationIgnored private var pollingTask: Task<Void, Never>?

    deinit {
        pollingTask?.cancel()
    }

    var isRunning: Bool {
        isSubmitting || run?.status == .queued || run?.status == .running
    }

    var canPromote: Bool {
        run?.status == .completed && run?.sessionFile?.isEmpty == false && !isPromoting
    }

    func submit(
        prompt: String,
        machineID: String,
        mode: HeadlessAgentRunMode = .ask,
        model: HerdrAppModel
    ) async {
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrompt.isEmpty, !isRunning else { return }

        stopPolling()
        self.machineID = machineID
        isSubmitting = true
        errorMessage = nil
        do {
            let started = try await model.startHeadlessAgent(
                prompt: normalizedPrompt,
                machineID: machineID,
                mode: mode
            )
            run = started
            isSubmitting = false
            if !started.status.isTerminal {
                beginPolling(runID: started.id, machineID: machineID, model: model)
            }
        } catch {
            isSubmitting = false
            errorMessage = error.localizedDescription
        }
    }

    func cancel(model: HerdrAppModel) async {
        guard let run, let machineID, isRunning else { return }
        stopPolling()
        do {
            self.run = try await model.cancelHeadlessAgent(runID: run.id, machineID: machineID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func promote(
        workspaceID: String?,
        model: HerdrAppModel
    ) async -> HerdrPane? {
        guard let run, let machineID, canPromote else { return nil }
        isPromoting = true
        errorMessage = nil
        defer { isPromoting = false }
        do {
            let result = try await model.promoteHeadlessAgent(
                runID: run.id,
                machineID: machineID,
                workspaceID: workspaceID
            )
            self.run = result.run
            return result.pane
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func reset() {
        guard !isRunning else { return }
        stopPolling()
        run = nil
        machineID = nil
        errorMessage = nil
    }

    func discard(model: HerdrAppModel) async {
        guard let run, let machineID, !isRunning else { return }
        stopPolling()
        do {
            try await model.deleteHeadlessAgent(runID: run.id, machineID: machineID)
        } catch {
            errorMessage = error.localizedDescription
        }
        self.run = nil
        self.machineID = nil
    }

    func close(model: HerdrAppModel) async {
        guard !isSubmitting else { return }
        stopPolling()
        if let run, let machineID {
            if isRunning,
               let cancelled = try? await model.cancelHeadlessAgent(
                   runID: run.id,
                   machineID: machineID
               ) {
                self.run = cancelled
            }
            if self.run?.status.isTerminal == true {
                try? await model.deleteHeadlessAgent(runID: run.id, machineID: machineID)
            }
        }
        run = nil
        machineID = nil
        errorMessage = nil
    }

    private func beginPolling(runID: String, machineID: String, model: HerdrAppModel) {
        pollingTask = Task { [weak self] in
            var pollingDelay: Duration = .milliseconds(700)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: pollingDelay)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                do {
                    let latest = try await model.fetchHeadlessAgent(runID: runID, machineID: machineID)
                    guard self.run?.id == runID else { return }
                    self.run = latest
                    self.errorMessage = nil
                    pollingDelay = .milliseconds(700)
                    if latest.status.isTerminal {
                        self.pollingTask = nil
                        return
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    self.errorMessage = error.localizedDescription
                    pollingDelay = .seconds(2)
                }
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }
}
