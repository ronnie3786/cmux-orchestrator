import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Notification metadata", .serialized)
@MainActor
struct NotificationManagerTests {
    @Test("Alert notification metadata includes the machine-scoped routing context")
    func userInfoIncludesMachineID() {
        let alert = HerdrAlert(
            id: "alert-1",
            workspaceID: "workspace-1",
            paneID: "workspace-1:pane-1",
            status: .blocked,
            title: "Needs input",
            message: "Confirm deployment",
            createdAt: "2026-08-25T12:00:00Z",
            isRead: false
        ).stamped(machineID: "machine-1")

        #expect(NotificationManager.userInfo(for: alert) == [
            "workspace_id": "workspace-1",
            "pane_id": "workspace-1:pane-1",
            "alert_id": alert.id,
            "machine_id": "machine-1",
        ])
    }

    @Test("Notification pane routing scopes current notifications and preserves legacy pane IDs")
    func resolvedPaneIDScopesMachineAndSupportsLegacyKeys() {
        let paneID = "workspace-1:pane-1"
        #expect(
            HerdrMacAppDelegate.resolvedPaneID(fromUserInfo: [
                "pane_id": paneID,
                "machine_id": "machine-1",
            ]) == MachineScopedID.compose(machineID: "machine-1", rawID: paneID)
        )
        #expect(HerdrMacAppDelegate.resolvedPaneID(fromUserInfo: ["pane_id": paneID]) == paneID)
        #expect(HerdrMacAppDelegate.resolvedPaneID(fromUserInfo: ["paneId": paneID]) == paneID)
        #expect(HerdrMacAppDelegate.resolvedPaneID(fromUserInfo: [:]) == nil)
    }

    @Test("Notification pane URLs safely round-trip machine-scoped IDs")
    func notificationPaneURLRoundTripsMachineScopedID() throws {
        let paneID = "machine-1|workspace-1:pane-1"
        let url = try #require(HerdrMacAppDelegate.notificationPaneURL(for: paneID))

        #expect(url.scheme == "herdr")
        #expect(url.host == "pane")
        #expect(HerdrAppModel.paneID(from: url) == paneID)
    }
}
