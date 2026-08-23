import Foundation
import Observation
import os

private let cleanupLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "herdr-harness-mac",
    category: "cleanup"
)

@MainActor
@Observable
final class CleanupRunController {
    enum State: Equatable {
        case idle
        case running(CleanupRunEnvelope)
        case report(CleanupRunEnvelope)
        case failure(String)
        case applying
        case applied(CleanupApplyResponse, CleanupRunEnvelope)
    }

    var state: State = .idle
    private(set) var activeRunID: String?
    private(set) var lastEnvelope: CleanupRunEnvelope?
    private(set) var consecutivePollFailures = 0
    private(set) var lastPollFailureMessage: String?
    private(set) var lastPollSucceededAt: Date?
    static let maxConsecutivePollFailures = 8

    private let isDemoMode: Bool
    private let pollInterval: Duration
    private let demoPhaseInterval: Duration
    private let startRequest: (CleanupStartRunRequest) async throws -> CleanupStartRunResponse
    private let fetchRun: (String) async throws -> CleanupRunEnvelope
    private let applyRun: (String, [String], [String]) async throws -> CleanupApplyResponse
    private let cancel: (String) async throws -> Void
    private let runContext: String
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var pollingGeneration = 0

    init(
        isDemoMode: Bool,
        pollInterval: Duration = .seconds(1),
        demoPhaseInterval: Duration = .seconds(1),
        runContext: String = "",
        start: @escaping (CleanupStartRunRequest) async throws -> CleanupStartRunResponse,
        fetch: @escaping (String) async throws -> CleanupRunEnvelope,
        apply: @escaping (String, [String], [String]) async throws -> CleanupApplyResponse,
        cancel: @escaping (String) async throws -> Void
    ) {
        self.isDemoMode = isDemoMode
        self.pollInterval = pollInterval
        self.demoPhaseInterval = demoPhaseInterval
        startRequest = start
        fetchRun = fetch
        applyRun = apply
        self.cancel = cancel
        self.runContext = runContext
    }

    deinit { pollingTask?.cancel() }

    func start() async {
        stopPolling()
        activeRunID = nil
        lastEnvelope = nil
        resetPollFailureState()
        lastPollSucceededAt = nil
        if isDemoMode {
            let envelope = Self.demoRunningSnapshot(phase: .collecting)
            activeRunID = envelope.run.runID
            lastEnvelope = envelope
            transition(to: .running(envelope), runID: envelope.run.runID)
            pollingTask = Task { [weak self] in
                await self?.advanceDemo()
            }
            return
        }

        let settings = CleanupSettings.load(from: .standard)
        do {
            let response = try await startRequest(
                CleanupStartRunRequest(
                    model: settings.model.isEmpty ? nil : settings.model,
                    thinkingLevel: settings.thinkingLevel,
                    costThresholdUSD: settings.costThresholdUSD,
                    tailLines: nil,
                    keepEvidence: nil,
                    workspaceIDs: nil
                )
            )
            let envelope = Self.initialEnvelope(for: response, settings: settings)
            activeRunID = response.runID
            lastEnvelope = envelope
            transition(to: .running(envelope), runID: response.runID)
            cleanupLog.info("run started id=\(response.runID) \(self.runContext)")
            beginPolling(runID: response.runID)
        } catch {
            transition(to: .failure(error.localizedDescription))
        }
    }

    func retry() async {
        guard let runID = activeRunID else {
            cleanupLog.info("retry requested without an active run")
            await start()
            return
        }

        cleanupLog.info("retry requested run=\(runID)")
        stopPolling()
        resetPollFailureState()
        if let lastEnvelope {
            transition(to: .running(lastEnvelope), runID: runID)
        }
        await poll(runID: runID)
        guard case .running = state, activeRunID == runID else { return }
        beginPolling(runID: runID)
    }

    func startOver() async {
        cleanupLog.info("start over requested run=\(self.activeRunID ?? "none")")
        if let runID = activeRunID {
            stopPolling()
            do {
                try await cancel(runID)
            } catch {
                // Cancellation is best-effort. Starting a new run is still the user's explicit intent.
            }
        }
        activeRunID = nil
        lastEnvelope = nil
        resetPollFailureState()
        lastPollSucceededAt = nil
        transition(to: .idle)
        await start()
    }

    func apply(paneIDs: [String], workspaceIDs: [String]) async {
        guard case let .report(envelope) = state else { return }
        let runID = envelope.run.runID
        cleanupLog.info("apply requested run=\(runID)")
        transition(to: .applying, runID: runID)
        do {
            let response = try await applyRun(envelope.run.runID, paneIDs, workspaceIDs)
            transition(to: .applied(response, envelope), runID: runID)
        } catch {
            transition(to: .failure(error.localizedDescription), runID: runID)
        }
    }

    func cancelRun() async {
        guard let runID = activeRunID else { return }
        cleanupLog.info("cancel requested run=\(runID)")
        stopPolling()
        do {
            try await cancel(runID)
        } catch {
            // Cancellation is best-effort. The next user action can safely retry.
        }
        activeRunID = nil
        lastEnvelope = nil
        resetPollFailureState()
        lastPollSucceededAt = nil
        transition(to: .idle, runID: runID)
    }

    func stopPolling() {
        pollingGeneration += 1
        pollingTask?.cancel()
        pollingTask = nil
    }

    func resumeIfNeeded() {
        guard case .running = state, let runID = activeRunID, pollingTask == nil else { return }
        cleanupLog.info("reattaching polling run=\(runID)")
        beginPolling(runID: runID)
    }

    private func beginPolling(runID: String) {
        let pollInterval = self.pollInterval
        pollingGeneration += 1
        let generation = pollingGeneration
        pollingTask = Task { [weak self, pollInterval, generation] in
            var exitReason = "finished"
            defer {
                self?.clearPollingTask(generation: generation)
                cleanupLog.info("polling exited run=\(runID): \(exitReason)")
            }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: pollInterval)
                } catch {
                    exitReason = Task.isCancelled ? "cancelled" : "sleep interrupted"
                    return
                }
                guard !Task.isCancelled else {
                    exitReason = "cancelled"
                    return
                }
                guard let self else {
                    exitReason = "controller released"
                    return
                }
                guard self.activeRunID == runID else {
                    exitReason = "active run changed"
                    return
                }
                await self.poll(runID: runID)
                guard case .running = self.state, self.activeRunID == runID else {
                    exitReason = self.consecutivePollFailures >= Self.maxConsecutivePollFailures
                        ? "failure cap reached"
                        : "state left running"
                    return
                }
            }
            exitReason = "cancelled"
        }
    }

    private func poll(runID: String) async {
        guard activeRunID == runID else { return }
        do {
            let envelope = try await fetchRun(runID)
            guard activeRunID == runID else { return }
            resetPollFailureState()
            lastPollSucceededAt = .now
            lastEnvelope = envelope
            if envelope.run.status.isTerminal {
                if envelope.workspaces != nil {
                    transition(to: .report(envelope), runID: runID)
                } else {
                    transition(to: .failure(Self.failureMessage(for: envelope.run)), runID: runID)
                }
            } else {
                transition(to: .running(envelope), runID: runID)
            }
        } catch {
            guard activeRunID == runID else { return }
            consecutivePollFailures += 1
            lastPollFailureMessage = error.localizedDescription
            cleanupLog.error("poll failed run=\(runID) count=\(self.consecutivePollFailures): \(error.localizedDescription)")
            if consecutivePollFailures >= Self.maxConsecutivePollFailures {
                transition(
                    to: .failure(
                        "\(error.localizedDescription) (run \(runID), after \(Self.maxConsecutivePollFailures) failed polls)"
                    ),
                    runID: runID
                )
            }
        }
    }

    private func advanceDemo() async {
        for phase in [CleanupPhase.judging, .gating] {
            do {
                try await Task.sleep(for: demoPhaseInterval)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let envelope = Self.demoRunningSnapshot(phase: phase)
            lastEnvelope = envelope
            transition(to: .running(envelope), runID: envelope.run.runID)
        }
        do {
            try await Task.sleep(for: demoPhaseInterval)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        let envelope = Self.demoReport()
        lastEnvelope = envelope
        transition(to: .report(envelope), runID: envelope.run.runID)
    }

    private func resetPollFailureState() {
        consecutivePollFailures = 0
        lastPollFailureMessage = nil
    }

    private func clearPollingTask(generation: Int) {
        guard pollingGeneration == generation else { return }
        pollingTask = nil
    }

    private func transition(to newState: State, runID: String? = nil) {
        let oldLabel = Self.stateLabel(state)
        state = newState
        cleanupLog.info(
            "state \(oldLabel) -> \(Self.stateLabel(newState)) run=\(runID ?? self.activeRunID ?? "none")"
        )
    }

    private static func stateLabel(_ state: State) -> String {
        switch state {
        case .idle: "idle"
        case .running: "running"
        case .report: "report"
        case let .failure(message): "failure: \(message)"
        case .applying: "applying"
        case .applied: "applied"
        }
    }

    private static func initialEnvelope(
        for response: CleanupStartRunResponse,
        settings: CleanupSettings
    ) -> CleanupRunEnvelope {
        CleanupRunEnvelope(
            ok: response.ok,
            run: CleanupRun(
                runID: response.runID,
                status: response.status,
                phase: .collecting,
                phaseDetail: "Capturing workspace and pane metadata",
                progress: CleanupProgress(done: 0, total: 1),
                config: CleanupRunConfig(
                    model: settings.model.isEmpty ? nil : settings.model,
                    thinkingLevel: settings.thinkingLevel,
                    costThresholdUSD: settings.costThresholdUSD,
                    tailLines: nil,
                    minConfidence: nil
                )
            ),
            workspaces: nil,
            summary: nil
        )
    }

    private static func failureMessage(for run: CleanupRun) -> String {
        var message = run.error ?? "Cleanup failed"
        if let lastError = run.judge?.lastError, !lastError.isEmpty, lastError != message {
            message += "\n\nJudge error: \(lastError)"
        }
        return message
    }

    static func demoRunningSnapshot(phase: CleanupPhase) -> CleanupRunEnvelope {
        let detail: String
        let progress: CleanupProgress
        let history: [CleanupPhaseHistoryEntry]
        switch phase {
        case .collecting:
            detail = "Capturing pane 4 of 7"
            progress = CleanupProgress(done: 4, total: 7)
            history = [CleanupPhaseHistoryEntry(phase: .collecting, startedAt: "2026-08-21T20:04:11Z", finishedAt: nil, detail: nil)]
        case .judging:
            detail = "Judging workspace \"fix-login-flake\" (batch 1 of 2)"
            progress = CleanupProgress(done: 1, total: 2)
            history = [
                CleanupPhaseHistoryEntry(phase: .collecting, startedAt: "2026-08-21T20:04:11Z", finishedAt: "2026-08-21T20:04:15Z", detail: "Captured 7 panes across 2 workspaces"),
                CleanupPhaseHistoryEntry(phase: .judging, startedAt: "2026-08-21T20:04:15Z", finishedAt: nil, detail: nil),
            ]
        case .gating:
            detail = "Checking safety rails before making recommendations"
            progress = CleanupProgress(done: 5, total: 7)
            history = [
                CleanupPhaseHistoryEntry(phase: .collecting, startedAt: "2026-08-21T20:04:11Z", finishedAt: "2026-08-21T20:04:15Z", detail: "Captured 7 panes across 2 workspaces"),
                CleanupPhaseHistoryEntry(phase: .judging, startedAt: "2026-08-21T20:04:15Z", finishedAt: "2026-08-21T20:04:42Z", detail: "Reviewed 2 workspace batches"),
                CleanupPhaseHistoryEntry(phase: .gating, startedAt: "2026-08-21T20:04:42Z", finishedAt: nil, detail: nil),
            ]
        case .done, .failed:
            return demoReport()
        }
        return CleanupRunEnvelope(
            ok: true,
            run: CleanupRun(
                runID: "clr_demo",
                status: phase == .collecting ? .collecting : phase == .judging ? .judging : .gating,
                phase: phase,
                phaseDetail: detail,
                progress: progress,
                phaseHistory: history,
                startedAt: "2026-08-21T20:04:11Z",
                session: "default",
                config: demoConfig
            ),
            workspaces: nil,
            summary: nil
        )
    }

    static func demoReport() -> CleanupRunEnvelope {
        let finishedAt = "2026-08-21T20:06:02Z"
        return CleanupRunEnvelope(
            ok: true,
            run: CleanupRun(
                runID: "clr_demo",
                status: .done,
                phase: .done,
                phaseDetail: "Cleanup report ready for your review",
                progress: CleanupProgress(done: 2, total: 2),
                phaseHistory: [
                    CleanupPhaseHistoryEntry(phase: .collecting, startedAt: "2026-08-21T20:04:11Z", finishedAt: "2026-08-21T20:04:15Z", detail: "Captured 7 panes across 2 workspaces"),
                    CleanupPhaseHistoryEntry(phase: .judging, startedAt: "2026-08-21T20:04:15Z", finishedAt: "2026-08-21T20:05:38Z", detail: "Reviewed 2 workspace batches"),
                    CleanupPhaseHistoryEntry(phase: .gating, startedAt: "2026-08-21T20:05:38Z", finishedAt: finishedAt, detail: "Applied deterministic safety rails"),
                ],
                startedAt: "2026-08-21T20:04:11Z",
                finishedAt: finishedAt,
                session: "default",
                config: demoConfig,
                judge: CleanupJudgeSummary(batches: 2, failedBatches: 0, costUSD: 0.031, durationMs: 83_210, lastError: nil)
            ),
            workspaces: [demoWorkspaceOne, demoWorkspaceTwo],
            summary: CleanupSummary(
                panesScanned: 7,
                closeCandidates: 3,
                railBlocked: 2,
                costFlags: [CleanupCostFlag(paneID: "w3:p1", costUSD: 3.41)],
                totalKnownCostUSD: 5.87,
                unknownCostPanes: 2
            )
        )
    }

    private static let demoConfig = CleanupRunConfig(
        model: "custom-lux-dspark/qwen3.8-27b-nvfp4-dspark",
        thinkingLevel: .medium,
        costThresholdUSD: 2.0,
        tailLines: 400,
        minConfidence: 0.6
    )

    private static let demoWorkspaceOne = CleanupWorkspaceReport(
        workspaceID: "w3",
        label: "fix-login-flake",
        workspaceCloseRecommended: false,
        workspaceSafeToClose: false,
        workspaceBlockedBy: ["R6:pane_blocked"],
        git: CleanupGitStatus(state: .clean),
        panes: [
            CleanupPaneReport(paneID: "w3:p1", title: "pi · fix-login-flake", agentKind: "pi", agentStatus: .done, classification: .completed, confidence: 0.92, reason: "Final turn reports a merged PR, and the done alert is six hours old.", closeRecommended: true, safeToClose: true, blockedBy: [], costUSD: 3.41, costSource: "sessionFile", costOverThreshold: true, signals: CleanupSignals(doneAlertAgeSeconds: 21_600, revisionChanged: false, sessionFileAgeSeconds: 22_110, starred: false, focused: false, unreadAlerts: 0)),
            CleanupPaneReport(paneID: "w3:p2", title: "tests · fix-login-flake", agentKind: "shell", agentStatus: .working, classification: .active, confidence: 0.88, reason: "The test runner produced new output during the check.", closeRecommended: false, safeToClose: false, blockedBy: ["R1:working", "R4:active_output"], costUSD: nil, costSource: nil, costOverThreshold: false, signals: CleanupSignals(doneAlertAgeSeconds: nil, revisionChanged: true, sessionFileAgeSeconds: nil, starred: false, focused: false, unreadAlerts: 0)),
            CleanupPaneReport(paneID: "w3:p3", title: "notes · fix-login-flake", agentKind: "shell", agentStatus: .idle, classification: .stale, confidence: 0.78, reason: "No output or alerts suggest this shell is still needed.", closeRecommended: true, safeToClose: true, blockedBy: [], costUSD: nil, costSource: nil, costOverThreshold: false, signals: CleanupSignals(doneAlertAgeSeconds: nil, revisionChanged: false, sessionFileAgeSeconds: nil, starred: false, focused: false, unreadAlerts: 0)),
        ]
    )

    private static let demoWorkspaceTwo = CleanupWorkspaceReport(
        workspaceID: "w9",
        label: "release-check",
        workspaceCloseRecommended: false,
        workspaceSafeToClose: false,
        workspaceBlockedBy: ["R2:focused_workspace", "R6:git_unpushed"],
        git: CleanupGitStatus(state: .unpushed),
        panes: [
            CleanupPaneReport(paneID: "w9:p1", title: "pi · release-check", agentKind: "pi", agentStatus: .done, classification: .needsHuman, confidence: 0.63, reason: "The release checklist is complete, but the workspace has unpushed commits.", closeRecommended: false, safeToClose: false, blockedBy: ["R2:focused_workspace", "R6:git_unpushed"], costUSD: 2.46, costSource: "bridge", costOverThreshold: true, signals: CleanupSignals(doneAlertAgeSeconds: 3_600, revisionChanged: false, sessionFileAgeSeconds: 3_900, starred: false, focused: true, unreadAlerts: 0)),
            CleanupPaneReport(paneID: "w9:p2", title: "deploy log", agentKind: "shell", agentStatus: .idle, classification: .stale, confidence: 0.81, reason: "The deploy log has been idle since the completed rollout.", closeRecommended: true, safeToClose: true, blockedBy: [], costUSD: nil, costSource: nil, costOverThreshold: false, signals: CleanupSignals(doneAlertAgeSeconds: nil, revisionChanged: false, sessionFileAgeSeconds: nil, starred: false, focused: false, unreadAlerts: 0)),
        ]
    )
}
