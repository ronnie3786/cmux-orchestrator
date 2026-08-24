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
        #expect(report.summary?.workspaceTitles == ["Fix Login Flake", "Release Check"])
        #expect(report.summary?.workspaceSummaries?.count == 2)
        #expect(report.summary?.activePiSessions == 2)
        #expect(report.workspaces?.flatMap(\.panes).contains(where: { $0.piSession?.active == true }) == true)
    }

    @Test("Demo cleanup apply reports workspace, Pi-session, and ledger counts")
    func demoApplySummary() async throws {
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"])

        let response = try await model.applyCleanupRun(
            machineID: "demo1",
            runID: "clr_demo",
            paneIDs: ["w3:p1"],
            workspaceIDs: ["w3"]
        )

        #expect(response.applied.panes == [])
        #expect(response.applied.workspaces == ["w3"])
        #expect(response.deduplicatedPaneIDs == ["w3:p1"])
        #expect(response.piSessions?.ended == 1)
        #expect(response.ledger?.recordsAppended == 1)
        #expect(response.ledger?.records.first?.pane.id == "w3:p1")
        #expect(model.toastMessage == "Closed 1 workspace. Ended 1 Pi session. Saved 1 pane-session record.")
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
        #expect(controller.consecutivePollFailures == 0)
    }

    @Test("Polling keeps a backend applying run active")
    func pollingKeepsApplyingRunActive() async throws {
        let envelope = CleanupRunController.demoRunningSnapshot(phase: .applying)
        let controller = CleanupRunController(
            isDemoMode: false,
            pollInterval: .milliseconds(1),
            start: { _ in CleanupStartRunResponse(ok: true, runID: "clr_demo", status: .collecting) },
            fetch: { _ in envelope },
            apply: { _, _, _ in CleanupApplyResponse(applied: CleanupAppliedItems(panes: [], workspaces: []), skipped: []) },
            cancel: { _ in }
        )
        defer { controller.stopPolling() }

        await controller.start()
        guard try await waitForApplyingRun(from: controller) else {
            Issue.record("Timed out waiting for the backend applying state")
            return
        }
        guard case let .running(current) = controller.state else {
            Issue.record("Expected applying GET state to remain a running cleanup")
            return
        }

        #expect(current.run.status == .applying)
        #expect(current.run.phase == .applying)
        #expect(current.run.status.isTerminal == false)
    }

    @Test("A failed async apply presents its confirmed partial result")
    func failedAsyncApplyPresentsPartialResult() async {
        let report = CleanupRunController.demoReport()
        let partial = CleanupApplyResponse(
            applied: CleanupAppliedItems(panes: ["w3:p1"], workspaces: []),
            skipped: [CleanupSkippedItem(id: "w3:p2", reason: "R8:state_changed")],
            complete: false,
            error: "Fresh workspace snapshot failed"
        )
        let controller = CleanupRunController(
            isDemoMode: false,
            start: { _ in CleanupStartRunResponse(ok: true, runID: "clr_demo", status: .collecting) },
            fetch: { _ in report },
            apply: { _, _, _ in partial },
            cancel: { _ in }
        )
        controller.state = .report(report)

        await controller.apply(paneIDs: ["w3:p1", "w3:p2"], workspaceIDs: [])

        guard case let .applied(response, originalReport) = controller.state else {
            Issue.record("Expected a partial apply response instead of a generic failure")
            return
        }
        #expect(response.error == "Fresh workspace snapshot failed")
        #expect(response.applied.panes == ["w3:p1"])
        #expect(originalReport.run.runID == report.run.runID)
    }

    @Test("Unknown apply status keeps the selection and recovers through Retry Status")
    func unknownApplyStatusRecoversWithOriginalSelection() async {
        let report = CleanupRunController.demoReport()
        let partial = CleanupApplyResponse(
            applied: CleanupAppliedItems(panes: ["w3:p1"], workspaces: []),
            skipped: [CleanupSkippedItem(id: "w3:p2", reason: "close_failed")],
            complete: false,
            error: "Pane w3:p2 could not be closed"
        )
        let script = CleanupApplyRecoveryScript(runID: report.run.runID, finalResponse: partial)
        let controller = CleanupRunController(
            isDemoMode: false,
            start: { _ in CleanupStartRunResponse(ok: true, runID: report.run.runID, status: .collecting) },
            fetch: { _ in report },
            applyWithProgress: { runID, paneIDs, workspaceIDs, onProgress in
                try await script.apply(
                    runID: runID,
                    paneIDs: paneIDs,
                    workspaceIDs: workspaceIDs,
                    onProgress: onProgress
                )
            },
            cancel: { _ in }
        )
        controller.state = .report(report)

        await controller.apply(paneIDs: ["w3:p1", "w3:p2"], workspaceIDs: ["w3"])

        guard case let .applyStatusUnknown(message) = controller.state else {
            Issue.record("Expected a locked unknown apply status")
            return
        }
        #expect(message.contains("may still be closing panes"))
        #expect(controller.latestApplyEnvelope?.run.phaseDetail == "Ending Pi session before closing pane 1 of 2")
        #expect(controller.latestApplyEnvelope?.applyResult?.piSessions?.ended == 1)

        await controller.retryApplyStatus()

        guard case let .applied(response, originalReport) = controller.state else {
            Issue.record("Expected Retry Status to recover into the partial applied result")
            return
        }
        #expect(response == partial)
        #expect(originalReport.run.runID == report.run.runID)
        #expect(await script.calls() == 2)
        #expect(await script.selections().allSatisfy {
            $0.paneIDs == ["w3:p1", "w3:p2"] && $0.workspaceIDs == ["w3"]
        })
    }

    @Test("Polling prioritizes a failed applyResult over the stale report payload")
    func pollingPrioritizesFailedApplyResult() async throws {
        let report = CleanupRunController.demoReport()
        let partial = CleanupApplyResponse(
            applied: CleanupAppliedItems(panes: ["w3:p1"], workspaces: []),
            skipped: [CleanupSkippedItem(id: "w3:p2", reason: "close_failed")],
            complete: false,
            error: "Close verification failed"
        )
        let finalEnvelope = CleanupRunEnvelope(
            ok: true,
            run: CleanupRun(
                runID: "clr_apply_result",
                status: .failed,
                phase: .failed,
                error: "Close verification failed"
            ),
            workspaces: report.workspaces,
            summary: report.summary,
            applyResult: partial
        )
        let controller = CleanupRunController(
            isDemoMode: false,
            pollInterval: .milliseconds(1),
            start: { _ in CleanupStartRunResponse(ok: true, runID: "clr_apply_result", status: .collecting) },
            fetch: { _ in finalEnvelope },
            apply: { _, _, _ in partial },
            cancel: { _ in }
        )

        await controller.start()
        guard try await waitForApplied(from: controller) else {
            Issue.record("Timed out waiting for the failed apply result")
            return
        }
        guard case let .applied(response, envelope) = controller.state else {
            Issue.record("Expected the confirmed partial outcome, not the stale judge report")
            return
        }
        #expect(response.error == "Close verification failed")
        #expect(envelope.run.runID == finalEnvelope.run.runID)
    }

    @Test("Retry resumes a known run after polling fails repeatedly")
    func retryResumesKnownRun() async throws {
        let starts = CleanupStartCounter()
        let script = CleanupFetchScript(failuresBeforeSuccess: 8)
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
        guard case let .failure(message) = controller.state else {
            Issue.record("Expected a cleanup poll failure")
            return
        }
        #expect(message.contains("network blip"))
        #expect(message.contains("clr_scripted"))

        await script.allowSuccess()
        await controller.retry()
        guard try await waitForReport(from: controller) else {
            Issue.record("Timed out waiting for cleanup retry to resume the known run")
            return
        }
        #expect(await starts.count() == 1)
    }

    @Test("Resuming a running controller restarts a stopped polling loop")
    func resumeIfNeededRestartsStoppedPolling() async throws {
        let counter = CleanupCounter()
        let controller = CleanupRunController(
            isDemoMode: false,
            pollInterval: .milliseconds(1),
            start: { _ in CleanupStartRunResponse(ok: true, runID: "clr_resume", status: .collecting) },
            fetch: { _ in await counter.nextEnvelope() },
            apply: { _, _, _ in CleanupApplyResponse(applied: CleanupAppliedItems(panes: [], workspaces: []), skipped: []) },
            cancel: { _ in }
        )

        await controller.start()
        controller.stopPolling()
        controller.resumeIfNeeded()

        guard try await waitForReport(from: controller) else {
            Issue.record("Timed out waiting for resumed cleanup polling")
            return
        }
        #expect(await counter.count() >= 2)
    }

    @Test("Resuming an idle controller is a no-op")
    func resumeIfNeededIsNoOpWhileIdle() async throws {
        let starts = CleanupStartCounter()
        let controller = CleanupRunController(
            isDemoMode: false,
            pollInterval: .milliseconds(1),
            start: { _ in await starts.start() },
            fetch: { _ in CleanupRunController.demoReport() },
            apply: { _, _, _ in CleanupApplyResponse(applied: CleanupAppliedItems(panes: [], workspaces: []), skipped: []) },
            cancel: { _ in }
        )

        controller.resumeIfNeeded()
        try await Task.sleep(for: .milliseconds(10))

        #expect(controller.state == .idle)
        #expect(await starts.count() == 0)
    }

    @Test("Cleanup polling without a client reports the affected machine")
    func fetchCleanupRunWithoutClientIsDescriptive() async throws {
        let suiteName = "CleanupRunControllerTests.noClient"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = HerdrAppModel(arguments: [], userDefaults: defaults)

        do {
            _ = try await model.fetchCleanupRun(machineID: "work-mac", runID: "clr_no_client")
            Issue.record("Expected a no-active-connection error")
        } catch let error as APIError {
            guard case let .noActiveConnection(machineID) = error else {
                Issue.record("Expected a no-active-connection error")
                return
            }
            #expect(machineID == "work-mac")
            #expect(error.localizedDescription.contains("work-mac"))
            #expect(error.localizedDescription.contains("active connection"))
        }
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

    private func waitForApplyingRun(from controller: CleanupRunController) async throws -> Bool {
        for _ in 0..<200 {
            if case let .running(envelope) = controller.state, envelope.run.status == .applying {
                return true
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        return false
    }

    private func waitForApplied(from controller: CleanupRunController) async throws -> Bool {
        for _ in 0..<200 {
            if case .applied = controller.state {
                return true
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        return false
    }
}

private actor CleanupApplyRecoveryScript {
    struct Selection: Sendable {
        let paneIDs: [String]
        let workspaceIDs: [String]
    }

    private let runID: String
    private let finalResponse: CleanupApplyResponse
    private var callCount = 0
    private var recordedSelections: [Selection] = []

    init(runID: String, finalResponse: CleanupApplyResponse) {
        self.runID = runID
        self.finalResponse = finalResponse
    }

    func apply(
        runID: String,
        paneIDs: [String],
        workspaceIDs: [String],
        onProgress: CleanupRunController.ApplyProgressHandler
    ) async throws -> CleanupApplyResponse {
        callCount += 1
        recordedSelections.append(Selection(paneIDs: paneIDs, workspaceIDs: workspaceIDs))
        if callCount == 1 {
            await onProgress(
                CleanupRunEnvelope(
                    ok: true,
                    run: CleanupRun(
                        runID: self.runID,
                        status: .applying,
                        phase: .applying,
                        phaseDetail: "Ending Pi session before closing pane 1 of 2",
                        progress: CleanupProgress(done: 1, total: 2)
                    ),
                    workspaces: nil,
                    summary: nil,
                    applyResult: CleanupApplyResponse(
                        applied: CleanupAppliedItems(panes: [], workspaces: []),
                        skipped: [],
                        piSessions: CleanupPiSessionApplySummary(ended: 1, failed: 0, results: [])
                    )
                )
            )
            throw APIError.cleanupApplyStatusUnknown(
                message: "The server may still be closing panes."
            )
        }

        await onProgress(
            CleanupRunEnvelope(
                ok: true,
                run: CleanupRun(
                    runID: self.runID,
                    status: .failed,
                    phase: .failed,
                    error: finalResponse.error
                ),
                workspaces: nil,
                summary: nil,
                applyResult: finalResponse
            )
        )
        return finalResponse
    }

    func calls() -> Int { callCount }
    func selections() -> [Selection] { recordedSelections }
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

private enum CleanupFetchScriptError: LocalizedError {
    case transient

    var errorDescription: String? {
        switch self {
        case .transient: "network blip"
        }
    }
}
