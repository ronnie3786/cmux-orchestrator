import UserNotifications

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

    static func removeDelivered(alertIDs: Set<String>) async {
        guard !alertIDs.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        let identifiers = await center.deliveredNotifications().compactMap { notification -> String? in
            let content = notification.request.content
            let alertID = content.userInfo["alertId"] as? String
                ?? content.userInfo["alert_id"] as? String
            guard alertIDs.contains(notification.request.identifier) ||
                    alertID.map { alertIDs.contains($0) } == true
            else { return nil }
            return notification.request.identifier
        }
        if !identifiers.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }

    /// The Mac app is co-located with the Herdr server and holds the `/api/v1/events`
    /// SSE stream open for as long as it runs, so alerts are delivered locally from
    /// `alert.created` instead of through APNs. Kept as a no-op so the shared
    /// `HerdrAppModel` smart-alert flow ports unchanged.
    static func registerForRemoteNotifications() {}

    static func setBadge(_ count: Int) async {
        try? await UNUserNotificationCenter.current().setBadgeCount(max(0, count))
    }
}
