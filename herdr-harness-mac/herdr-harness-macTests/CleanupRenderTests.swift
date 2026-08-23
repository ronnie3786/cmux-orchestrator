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
}
