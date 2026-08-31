import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Herdr HUD notification filter")
@MainActor
struct HerdrHudNotificationFilterTests {
    @Test("Pi chat panes are retained while other panes are excluded")
    func filtersPanes() throws {
        let piPane = try HerdrRenderFixtures.piCapablePane().stamped(machineID: "demo1")
        let nonPiPane = try nonPiPane().stamped(machineID: "demo1")

        #expect(HerdrHudNotificationFilter.panes([piPane, nonPiPane]) == [piPane])
    }

    @Test("Alerts retain only Pi chat pane alerts")
    func filtersAlertsByPiChatPane() throws {
        let piPane = try HerdrRenderFixtures.piCapablePane().stamped(machineID: "demo1")
        let nonPiPane = try nonPiPane().stamped(machineID: "demo1")
        let piAlert = alert(id: "pi", paneID: piPane.paneID)
        let nonPiAlert = alert(id: "non-pi", paneID: nonPiPane.paneID)
        let missingAlert = alert(id: "missing", paneID: "w1:gone")

        #expect(
            HerdrHudNotificationFilter.alerts(
                [piAlert, nonPiAlert, missingAlert],
                panes: [piPane, nonPiPane]
            ) == [piAlert]
        )
    }

    private func nonPiPane() throws -> HerdrPane {
        try JSONDecoder().decode(
            HerdrPane.self,
            from: Data("""
            {"pane_id":"w1:p2","workspace_id":"w1","tab_id":"w1:t1"}
            """.utf8)
        )
    }

    private func alert(id: String, paneID: String) -> HerdrAlert {
        HerdrAlert(
            id: id,
            workspaceID: "w1",
            paneID: paneID,
            status: .working,
            title: id,
            message: "Needs attention",
            createdAt: "2026-08-31T12:00:00Z",
            isRead: false
        )
        .stamped(machineID: "demo1")
    }
}
