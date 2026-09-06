import UserNotifications
import UIKit

@MainActor
enum NotificationManager {
    private static var inFlightAlertIDs: Set<String> = []
    private static var cancelledAlertIDs: Set<String> = []

    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .badge, .sound]
            )
        } catch {
            return false
        }
    }

    static func userInfo(for alert: HerdrAlert) -> [String: String] {
        [
            "workspace_id": alert.workspaceID,
            "pane_id": alert.paneID,
            "alert_id": alert.id,
            "machine_id": alert.machineID,
        ]
    }

    static func deliveryDelay(for alert: HerdrAlert, now: Date = .now, gracePeriod: TimeInterval = 60) -> TimeInterval {
        max(0, gracePeriod - now.timeIntervalSince(alert.createdDate ?? now))
    }

    static func matchesReadAlert(identifier: String, userInfo: [AnyHashable: Any], alertIDs: Set<String>) -> Bool {
        if alertIDs.contains(identifier) { return true }
        guard let alertID = userInfo["alertId"] as? String ?? userInfo["alert_id"] as? String else { return false }
        if let machineID = userInfo["machine_id"] as? String, !machineID.isEmpty,
           MachineScopedID.split(alertID) == nil {
            return alertIDs.contains(MachineScopedID.compose(machineID: machineID, rawID: alertID))
        }
        return alertIDs.contains(alertID)
    }

    static func post(_ alert: HerdrAlert, gracePeriod: TimeInterval = 60) async {
        guard !alert.isRead, inFlightAlertIDs.insert(alert.id).inserted else { return }
        defer {
            inFlightAlertIDs.remove(alert.id)
            cancelledAlertIDs.remove(alert.id)
        }
        let center = UNUserNotificationCenter.current()
        let existing = await center.pendingNotificationRequests().contains { $0.identifier == alert.id }
        let delivered = await center.deliveredNotifications().contains {
            matchesReadAlert(identifier: $0.request.identifier, userInfo: $0.request.content.userInfo, alertIDs: [alert.id])
        }
        guard !existing, !delivered, !cancelledAlertIDs.contains(alert.id) else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.message
        content.sound = .default
        content.interruptionLevel = alert.status == .blocked ? .timeSensitive : .active
        content.userInfo = userInfo(for: alert)
        let delay = deliveryDelay(for: alert, gracePeriod: gracePeriod)
        let trigger = delay > 0 ? UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false) : nil
        let request = UNNotificationRequest(identifier: alert.id, content: content, trigger: trigger)
        try? await center.add(request)
        if cancelledAlertIDs.contains(alert.id) {
            center.removePendingNotificationRequests(withIdentifiers: [alert.id])
            center.removeDeliveredNotifications(withIdentifiers: [alert.id])
        }
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
            ),
            gracePeriod: 0
        )
    }

    static func removeDelivered(alertIDs: Set<String>) async {
        guard !alertIDs.isEmpty else { return }
        cancelledAlertIDs.formUnion(inFlightAlertIDs.intersection(alertIDs))
        let center = UNUserNotificationCenter.current()
        let pendingIDs = await center.pendingNotificationRequests().compactMap { request in
            matchesReadAlert(identifier: request.identifier, userInfo: request.content.userInfo, alertIDs: alertIDs)
                ? request.identifier : nil
        }
        if !pendingIDs.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: pendingIDs)
        }
        let identifiers = await center.deliveredNotifications().compactMap { notification -> String? in
            let content = notification.request.content
            guard matchesReadAlert(identifier: notification.request.identifier, userInfo: content.userInfo, alertIDs: alertIDs) else { return nil }
            return notification.request.identifier
        }
        if !identifiers.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }

    static func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    static func setBadge(_ count: Int) async {
        try? await UNUserNotificationCenter.current().setBadgeCount(max(0, count))
    }
}
