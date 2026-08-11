import UIKit
import UserNotifications

@MainActor
final class HerdrAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private static var pendingPaneID: String?

    static func takePendingPaneID() -> String? {
        defer { pendingPaneID = nil }
        return pendingPaneID
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        NotificationCenter.default.post(name: .herdrPushToken, object: token)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let paneID = (userInfo["pane_id"] as? String) ?? (userInfo["paneId"] as? String) else {
            return
        }
        Self.pendingPaneID = paneID
        NotificationCenter.default.post(name: .herdrOpenPane, object: paneID)
    }
}

extension Notification.Name {
    static let herdrOpenPane = Notification.Name("HerdrOpenPane")
    static let herdrPushToken = Notification.Name("HerdrPushToken")
}
