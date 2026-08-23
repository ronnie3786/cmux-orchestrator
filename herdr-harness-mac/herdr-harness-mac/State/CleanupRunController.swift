import Foundation
import Observation

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

    private let isDemoMode: Bool
    private let pollInterval: Duration
    private let demoPhaseInterval: Duration
    private let startRequest: (CleanupStartRunRequest) async throws -> CleanupStartRunResponse
    private let fetchRun: (String) async throws -> CleanupRunEnvelope
    private let applyRun: (String, [String], [String]) async throws -> CleanupApplyResponse
    private let cancel: (String) async throws -> Void
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var consecutivePollFailures = 0
    private let maxConsecutivePollFailures = 3

    init(
        isDemoMode: Bool,
        pollInterval: Duration = .seconds(1),
        demoPhaseInterval: Duration = .seconds(1),
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
    }

    deinit { pollingTask?.cancel() }

    func start() async {
        stopPolling()
        activeRunID = nil
        lastEnvelope = nil
        consecutivePollFailures = 0
        if isDemoMode {
            let envelope = Self.demoRunningSnapshot(phase: .collecting)
            activeRunID = envelope.run.runID
            lastEnvelope = envelope
            state = .running(envelope)
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
            state = .running(envelope)
            beginPolling(runID: response.runID)
        } catch {
            state = .failure(error.localizedDescription)
        }
    }

    func retry() async {
        guard let runID = activeRunID else {
            await start()
            return
        }

        stopPolling()
        consecutivePollFailures = 0
        if let lastEnvelope {
            state = .running(lastEnvelope)
        }
        await poll(runID: runID)
        guard case .running = state, activeRunID == runID else { return }
        beginPolling(runID: runID)
    }

    func startOver() async {
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
        consecutivePollFailures = 0
        state = .idle
        await start()
    }

    func apply(paneIDs: [String], workspaceIDs: [String]) async {
        guard case let .report(envelope) = state else { return }
        state = .applying
        do {
            let response = try await applyRun(envelope.run.runID, paneIDs, workspaceIDs)
            state = .applied(response, envelope)
        } catch {
            state = .failure(error.localizedDescription)
        }
    }

    func cancelRun() async {
        guard let runID = activeRunID else { return }
        stopPolling()
        do {
            try await cancel(runID)
        } catch {
            // Cancellation is best-effort. The next user action can safely retry.
        }
        activeRunID = nil
        lastEnvelope = nil
        consecutivePollFailures = 0
        state = .idle
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func beginPolling(runID: String) {
        let pollInterval = self.pollInterval
        pollingTask = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: pollInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self, self.activeRunID == runID else { return }
                await self.poll(runID: runID)
                guard case .running = self.state, self.activeRunID == runID else { return }
            }
        }
    }

    private func poll(runID: String) async {
        guard activeRunID == runID else { return }
        do {
            let envelope = try await fetchRun(runID)
            guard activeRunID == runID else { return }
            consecutivePollFailures = 0
            lastEnvelope = envelope
            if envelope.run.status == .failed, envelope.workspaces == nil {
                state = .failure(envelope.run.error ?? "Cleanup failed")
            } else if envelope.run.status.isTerminal {
                state = .report(envelope)
            } else {
                state = .running(envelope)
            }
        } catch {
            guard activeRunID == runID else { return }
            consecutivePollFailures += 1
            if consecutivePollFailures >= maxConsecutivePollFailures {
                state = .failure(error.localizedDescription)
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
            state = .running(envelope)
        }
        do {
            try await Task.sleep(for: demoPhaseInterval)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        let envelope = Self.demoReport()
        lastEnvelope = envelope
        state = .report(envelope)
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
                judge: CleanupJudgeSummary(batches: 2, failedBatches: 0, costUSD: 0.031, durationMs: 83_210)
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
