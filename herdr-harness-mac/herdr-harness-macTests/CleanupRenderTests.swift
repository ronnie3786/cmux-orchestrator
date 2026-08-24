import Foundation
import SwiftUI
import Testing
@testable import herdr_harness_mac

@Suite("Cleanup screenshot renders", .serialized)
@MainActor
struct CleanupRenderTests {
    @Test("Cleanup report renders")
    func report() async throws {
        _ = HerdrRenderFixtures.demoModel()
        let controller = makeController()
        controller.state = .report(CleanupRunController.demoReport())
        let result = try await HerdrRenderHarness.render("09-cleanup-report.png", size: CGSize(width: 900, height: 760)) {
            CleanupSheet(target: target, controller: controller)
        }
        result.expectSubstantial()
    }

    @Test("Cleanup progress renders")
    func progress() async throws {
        _ = HerdrRenderFixtures.demoModel()
        let controller = makeController()
        controller.state = .running(CleanupRunController.demoRunningSnapshot(phase: .judging))
        let result = try await HerdrRenderHarness.render("10-cleanup-progress.png", size: CGSize(width: 900, height: 760)) {
            CleanupSheet(target: target, controller: controller)
        }
        result.expectSubstantial()
    }

    @Test("Cleanup report renders at the largest Herdr text size")
    func compactLargeTextReport() async throws {
        _ = HerdrRenderFixtures.demoModel()
        let controller = makeController()
        controller.state = .report(CleanupRunController.demoReport())
        let result = try await HerdrRenderHarness.render("11-cleanup-report-large-text.png", size: CGSize(width: 760, height: 600)) {
            CleanupSheet(target: target, controller: controller)
                .environment(\.herdrFontScale, .xxxLarge)
        }
        result.expectSubstantial()
    }

    @Test("Cleanup applying renders")
    func applying() async throws {
        _ = HerdrRenderFixtures.demoModel()
        let controller = makeController()
        controller.state = .applying(applyingEnvelope)
        let result = try await HerdrRenderHarness.render("12-cleanup-applying.png", size: CGSize(width: 900, height: 760)) {
            CleanupSheet(target: target, controller: controller)
        }
        result.expectSubstantial()
    }

    @Test("Cleanup unknown apply status renders a locked recovery state")
    func applyStatusUnknown() async throws {
        _ = HerdrRenderFixtures.demoModel()
        let controller = makeController()
        controller.state = .applyStatusUnknown(
            "Herdr could not confirm cleanup status. The server may still be ending sessions or closing panes."
        )
        let result = try await HerdrRenderHarness.render("14-cleanup-status-unknown.png", size: CGSize(width: 900, height: 760)) {
            CleanupSheet(target: target, controller: controller)
        }
        result.expectSubstantial()
    }

    @Test("Cleanup applied results render")
    func applied() async throws {
        _ = HerdrRenderFixtures.demoModel()
        let controller = makeController()
        controller.state = .applied(appliedResponse, CleanupRunController.demoReport())
        let result = try await HerdrRenderHarness.render("13-cleanup-applied.png", size: CGSize(width: 900, height: 760)) {
            CleanupSheet(target: target, controller: controller)
        }
        result.expectSubstantial()
    }

    private var target: CleanupSheetTarget {
        CleanupSheetTarget(id: "demo-cleanup", machineID: "demo1", machineName: "Demo Mac", workspaceID: nil, workspaceLabel: nil)
    }

    private func makeController() -> CleanupRunController {
        CleanupRunController(
            isDemoMode: true,
            start: { _ in CleanupStartRunResponse(ok: true, runID: "clr_demo", status: .collecting) },
            fetch: { _ in CleanupRunController.demoReport() },
            apply: { _, _, _ in CleanupApplyResponse(applied: CleanupAppliedItems(panes: [], workspaces: []), skipped: []) },
            cancel: { _ in }
        )
    }

    private var appliedResponse: CleanupApplyResponse {
        CleanupApplyResponse(
            applied: CleanupAppliedItems(panes: ["w3:p1"], workspaces: []),
            skipped: [CleanupSkippedItem(id: "w9:p1", reason: "R8:state_changed")],
            piSessions: CleanupPiSessionApplySummary(
                ended: 1,
                failed: 0,
                results: [
                    CleanupPiSessionApplyResult(
                        paneID: "w3:p1",
                        sessionID: "pi-session-fix-login",
                        wasActive: true,
                        quitAttempted: true,
                        quitSucceeded: true,
                        closeOutcome: "closed",
                        reason: nil
                    ),
                ]
            ),
            ledger: CleanupLedgerSummary(
                path: "/Users/demo/.config/herdr-harness/cleanup/pane-session-ledger.jsonl",
                recordsAppended: 1,
                records: []
            )
        )
    }

    private var applyingEnvelope: CleanupRunEnvelope {
        CleanupRunEnvelope(
            ok: true,
            run: CleanupRun(
                runID: "clr_demo",
                status: .applying,
                phase: .applying,
                phaseDetail: "Ending Pi session login-retry-8421 before closing pane 1 of 3",
                progress: CleanupProgress(done: 1, total: 3)
            ),
            workspaces: nil,
            summary: nil,
            applyResult: CleanupApplyResponse(
                applied: CleanupAppliedItems(panes: ["w3:p1"], workspaces: []),
                skipped: [CleanupSkippedItem(id: "w9:p1", reason: "R8:state_changed")],
                piSessions: CleanupPiSessionApplySummary(ended: 1, failed: 0, results: [])
            )
        )
    }
}
