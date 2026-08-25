import Testing
@testable import herdr_harness_ios

@Suite("Notification routing", .serialized)
@MainActor
struct NotificationManagerTests {
    @Test("Notification user info includes machine-scoped routing data")
    func notificationUserInfoIncludesMachineID() {
        let alert = HerdrAlert(
            id: "alert-1",
            workspaceID: "workspace-1",
            paneID: "workspace-1:pane-1",
            status: .blocked,
            title: "Needs input",
            message: "",
            createdAt: "2026-08-25T12:00:00Z",
            isRead: false
        ).stamped(machineID: "machine-1")

        let userInfo = NotificationManager.userInfo(for: alert)

        #expect(userInfo["machine_id"] == "machine-1")
        #expect(userInfo["workspace_id"] == "workspace-1")
        #expect(userInfo["pane_id"] == "workspace-1:pane-1")
        #expect(userInfo["alert_id"] == "machine-1|alert-1")
    }

    @Test("Notification routing scopes pane IDs when machine metadata is present")
    func resolvedPaneIDScopesPaneID() {
        let userInfo: [AnyHashable: Any] = [
            "machine_id": "machine-1",
            "pane_id": "workspace-1:pane-1",
        ]

        #expect(
            HerdrAppDelegate.resolvedPaneID(fromUserInfo: userInfo)
                == MachineScopedID.compose(machineID: "machine-1", rawID: "workspace-1:pane-1")
        )
    }

    @Test("Notification routing supports legacy raw pane ID keys")
    func resolvedPaneIDFallsBackToRawAndLegacyPaneID() {
        #expect(HerdrAppDelegate.resolvedPaneID(fromUserInfo: ["pane_id": "workspace-1:pane-1"]) == "workspace-1:pane-1")
        #expect(HerdrAppDelegate.resolvedPaneID(fromUserInfo: ["paneId": "workspace-1:pane-1"]) == "workspace-1:pane-1")
    }

    @Test("Notification routing rejects payloads without a pane ID")
    func resolvedPaneIDIsNilWithoutPaneID() {
        #expect(HerdrAppDelegate.resolvedPaneID(fromUserInfo: ["machine_id": "machine-1"]) == nil)
    }
}
