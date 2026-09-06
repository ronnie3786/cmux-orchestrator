import Foundation
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

    @Test("Local fallback preserves the unread minute, including delayed delivery failures")
    func localFallbackGracePeriod() {
        let alert = HerdrAlert(id: "a", workspaceID: "w", paneID: "p", status: .done,
                               title: "Done", message: "", createdAt: "2026-08-25T12:00:00Z", isRead: false)
        let created = alert.createdDate!
        #expect(NotificationManager.deliveryDelay(for: alert, now: created) == 60)
        #expect(NotificationManager.deliveryDelay(for: alert, now: created.addingTimeInterval(45)) == 15)
        #expect(NotificationManager.deliveryDelay(for: alert, now: created.addingTimeInterval(61)) == 0)
        #expect(NotificationManager.deliveryDelay(for: alert, now: created, gracePeriod: 0) == 0)
    }

    @Test("Read cleanup matches APNs raw IDs only on the right machine")
    func remoteReadCleanupScopesAlertID() {
        let payload: [AnyHashable: Any] = ["alertId": "a", "machine_id": "work"]
        #expect(NotificationManager.matchesReadAlert(identifier: "apns-uuid", userInfo: payload, alertIDs: ["work|a"]))
        #expect(!NotificationManager.matchesReadAlert(identifier: "apns-uuid", userInfo: payload, alertIDs: ["personal|a"]))
        #expect(!NotificationManager.matchesReadAlert(identifier: "apns-uuid", userInfo: payload, alertIDs: ["a"]))
    }

    @Test("Read cleanup preserves local scoped and legacy notification identifiers")
    func localReadCleanupUsesExistingScopedID() {
        #expect(NotificationManager.matchesReadAlert(identifier: "work|a", userInfo: [:], alertIDs: ["work|a"]))
        #expect(NotificationManager.matchesReadAlert(identifier: "uuid", userInfo: ["alert_id": "work|a", "machine_id": "work"], alertIDs: ["work|a"]))
        #expect(NotificationManager.matchesReadAlert(identifier: "uuid", userInfo: ["alertId": "a"], alertIDs: ["a"]))
    }
}
