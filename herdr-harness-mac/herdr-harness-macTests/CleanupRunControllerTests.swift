import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Cleanup run controller", .serialized)
@MainActor
struct CleanupRunControllerTests {
    @Test("Polling advances a running run to its report")
    func pollingProducesReport() async throws {
        let counter = CleanupCounter()
        let controller = CleanupRunController(
            isDemoMode: false,
            pollInterval: .milliseconds(1),
            start: { _ in CleanupStartRunResponse(ok: true, runID: "clr_test", status: .collecting) },
            fetch: { _ in await counter.nextEnvelope() },
            apply: { _, _, _ in CleanupApplyResponse(applied: CleanupAppliedItems(panes: [], workspaces: []), skipped: []) },
            cancel: { _ in }
        )

        await controller.start()
        guard try await waitForReport(from: controller) else {
            Issue.record("Timed out waiting for a cleanup report after polling")
            return
        }
        guard case let .report(report) = controller.state else {
            Issue.record("Expected a cleanup report after polling")
            return
        }
        #expect(report.run.status == .done)
        #expect(await counter.count() >= 2)
    }

    @Test("Stopping polling prevents additional fetches")
    func pollingStops() async throws {
        let counter = CleanupCounter()
        let controller = CleanupRunController(
            isDemoMode: false,
            pollInterval: .milliseconds(30),
            start: { _ in CleanupStartRunResponse(ok: true, runID: "clr_stop", status: .collecting) },
            fetch: { _ in await counter.nextEnvelope() },
            apply: { _, _, _ in CleanupApplyResponse(applied: CleanupAppliedItems(panes: [], workspaces: []), skipped: []) },
            cancel: { _ in }
        )

        await controller.start()
        controller.stopPolling()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await counter.count() == 0)
    }

    @Test("Demo mode reaches the rich canned report without network closures")
    func demoMode() async throws {
        let controller = CleanupRunController(
            isDemoMode: true,
            pollInterval: .milliseconds(1),
            demoPhaseInterval: .milliseconds(1),
            start: { _ in Issue.record("Demo must not start network work"); throw APIError.invalidResponse },
            fetch: { _ in Issue.record("Demo must not fetch network work"); throw APIError.invalidResponse },
            apply: { _, _, _ in CleanupApplyResponse(applied: CleanupAppliedItems(panes: [], workspaces: []), skipped: []) },
            cancel: { _ in }
        )

        await controller.start()
        guard try await waitForReport(from: controller) else {
            Issue.record("Timed out waiting for the canned cleanup report")
            return
        }
        guard case let .report(report) = controller.state else {
            Issue.record("Expected canned report")
            return
        }
        #expect(report.workspaces?.count == 2)
        #expect(report.workspaces?.flatMap(\.panes).contains(where: { !$0.blockedBy.isEmpty }) == true)
    }

    @Test("A transient fetch failure does not abandon an active run")
    func transientFetchFailureRecovers() async throws {
        let starts = CleanupStartCounter()
        let script = CleanupFetchScript(failuresBeforeSuccess: 1)
        let controller = CleanupRunController(
            isDemoMode: false,
            pollInterval: .milliseconds(1),
            start: { _ in await starts.start() },
            fetch: { _ in try await script.nextEnvelope() },
            apply: { _, _, _ in CleanupApplyResponse(applied: CleanupAppliedItems(panes: [], workspaces: []), skipped: []) },
            cancel: { _ in }
        )

        await controller.start()
        guard try await waitForReport(from: controller) else {
            Issue.record("Timed out waiting for recovery from a transient cleanup poll failure")
            return
        }
        #expect(await starts.count() == 1)
    }

    @Test("Retry resumes a known run after polling fails repeatedly")
    func retryResumesKnownRun() async throws {
        let starts = CleanupStartCounter()
        let script = CleanupFetchScript(failuresBeforeSuccess: 3)
        let controller = CleanupRunController(
            isDemoMode: false,
            pollInterval: .milliseconds(1),
            start: { _ in await starts.start() },
            fetch: { _ in try await script.nextEnvelope() },
            apply: { _, _, _ in CleanupApplyResponse(applied: CleanupAppliedItems(panes: [], workspaces: []), skipped: []) },
            cancel: { _ in }
        )

        await controller.start()
        guard try await waitForFailure(from: controller) else {
            Issue.record("Timed out waiting for the cleanup poll failure threshold")
            return
        }

        await script.allowSuccess()
        await controller.retry()
        guard try await waitForReport(from: controller) else {
            Issue.record("Timed out waiting for cleanup retry to resume the known run")
            return
        }
        #expect(await starts.count() == 1)
    }

    @Test("A partial run with a workspace payload remains a report")
    func partialRunWithPayloadProducesReport() async throws {
        let envelope = partialEnvelope(workspaces: [minimalWorkspaceReport])
        let controller = CleanupRunController(
            isDemoMode: false,
            pollInterval: .milliseconds(1),
            start: { _ in CleanupStartRunResponse(ok: true, runID: "clr_partial", status: .collecting) },
            fetch: { _ in envelope },
            apply: { _, _, _ in CleanupApplyResponse(applied: CleanupAppliedItems(panes: [], workspaces: []), skipped: []) },
            cancel: { _ in }
        )

        await controller.start()
        guard try await waitForReport(from: controller) else {
            Issue.record("Timed out waiting for a partial cleanup report")
            return
        }
        guard case let .report(report) = controller.state else {
            Issue.record("Expected a partial cleanup report")
            return
        }
        #expect(report.run.status == .partial)
        #expect(report.run.error == "pi_unavailable")
        #expect(report.workspaces?.isEmpty == false)
    }

    @Test("A partial run without a workspace payload shows both server errors")
    func partialRunWithoutPayloadProducesFailure() async throws {
        let envelope = partialEnvelope(workspaces: nil)
        let controller = CleanupRunController(
            isDemoMode: false,
            pollInterval: .milliseconds(1),
            start: { _ in CleanupStartRunResponse(ok: true, runID: "clr_partial", status: .collecting) },
            fetch: { _ in envelope },
            apply: { _, _, _ in CleanupApplyResponse(applied: CleanupAppliedItems(panes: [], workspaces: []), skipped: []) },
            cancel: { _ in }
        )

        await controller.start()
        guard try await waitForFailure(from: controller) else {
            Issue.record("Timed out waiting for partial cleanup failure")
            return
        }
        guard case let .failure(message) = controller.state else {
            Issue.record("Expected a partial cleanup failure")
            return
        }
        #expect(message.contains("pi_unavailable"))
        #expect(message.contains("context_deadline_exceeded"))
    }

    private func partialEnvelope(workspaces: [CleanupWorkspaceReport]?) -> CleanupRunEnvelope {
        CleanupRunEnvelope(
            ok: true,
            run: CleanupRun(
                runID: "clr_partial",
                status: .partial,
                phase: .failed,
                judge: CleanupJudgeSummary(
                    batches: 1,
                    failedBatches: 1,
                    costUSD: 0,
                    durationMs: 1,
                    lastError: "context_deadline_exceeded"
                ),
                error: "pi_unavailable"
            ),
            workspaces: workspaces,
            summary: nil
        )
    }

    private var minimalWorkspaceReport: CleanupWorkspaceReport {
        CleanupWorkspaceReport(
            workspaceID: "workspace-1",
            label: "Workspace",
            workspaceCloseRecommended: false,
            workspaceSafeToClose: false,
            workspaceBlockedBy: [],
            git: CleanupGitStatus(state: .clean),
            panes: [
                CleanupPaneReport(
                    paneID: "workspace-1:pane-1",
                    title: "Pane",
                    agentKind: "pi",
                    agentStatus: .idle,
                    classification: .stale,
                    confidence: 0.8,
                    reason: "Deterministic signal",
                    closeRecommended: false,
                    safeToClose: false,
                    blockedBy: [],
                    costUSD: nil,
                    costSource: nil,
                    costOverThreshold: false,
                    signals: nil
                )
            ]
        )
    }

    private func waitForReport(from controller: CleanupRunController) async throws -> Bool {
        if case .report = controller.state {
            return true
        }

        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(10))
            if case .report = controller.state {
                return true
            }
        }

        return false
    }

    private func waitForFailure(from controller: CleanupRunController) async throws -> Bool {
        if case .failure = controller.state {
            return true
        }

        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(10))
            if case .failure = controller.state {
                return true
            }
        }

        return false
    }
}

private actor CleanupCounter {
    private var calls = 0

    func nextEnvelope() async -> CleanupRunEnvelope {
        calls += 1
        let call = calls
        return await MainActor.run {
            call == 1 ? CleanupRunController.demoRunningSnapshot(phase: .collecting) : CleanupRunController.demoReport()
        }
    }

    func count() -> Int { calls }
}

private actor CleanupStartCounter {
    private var calls = 0

    func start() -> CleanupStartRunResponse {
        calls += 1
        return CleanupStartRunResponse(ok: true, runID: "clr_scripted", status: .collecting)
    }

    func count() -> Int { calls }
}

private actor CleanupFetchScript {
    private var failuresBeforeSuccess: Int
    private var successfulFetches = 0

    init(failuresBeforeSuccess: Int) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func nextEnvelope() async throws -> CleanupRunEnvelope {
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
            throw CleanupFetchScriptError.transient
        }

        successfulFetches += 1
        let successfulFetches = successfulFetches
        return await MainActor.run {
            successfulFetches == 1
                ? CleanupRunController.demoRunningSnapshot(phase: .collecting)
                : CleanupRunController.demoReport()
        }
    }

    func allowSuccess() {
        failuresBeforeSuccess = 0
    }
}

private enum CleanupFetchScriptError: Error {
    case transient
}
