import UserNotifications
import UIKit

@MainActor
enum NotificationManager {
    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .badge, .sound]
            )
        } catch {
            return false
        }
    }

    static func post(_ alert: HerdrAlert) async {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.message
        content.sound = .default
        content.interruptionLevel = alert.status == .blocked ? .timeSensitive : .active
        content.userInfo = [
            "workspace_id": alert.workspaceID,
            "pane_id": alert.paneID,
            "alert_id": alert.id,
        ]
        let request = UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func postTest() async {
        await post(
            HerdrAlert(
                id: "herdr-test-alert",
                workspaceID: "",
                paneID: "",
                status: .done,
                title: "Herdr alerts are ready",
                message: "You’ll hear when an agent needs you or finishes in the background.",
                createdAt: "",
                isRead: false
            )
        )
    }

    static func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    static func setBadge(_ count: Int) async {
        try? await UNUserNotificationCenter.current().setBadgeCount(max(0, count))
    }
}
