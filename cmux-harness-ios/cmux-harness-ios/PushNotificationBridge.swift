import Combine
import Foundation
import SwiftUI
import UIKit
import UserNotifications

struct PushApprovalNotification: Equatable, Identifiable, Sendable {
    var notificationID: String
    var workspaceID: String
    var workspaceUUID: String
    var surfaceID: String
    var workspaceName: String
    var reason: String
    var request: String

    var id: String { notificationID.isEmpty ? workspaceID : notificationID }

    init(
        notificationID: String,
        workspaceID: String,
        workspaceUUID: String,
        surfaceID: String,
        workspaceName: String,
        reason: String,
        request: String
    ) {
        self.notificationID = notificationID
        self.workspaceID = workspaceID
        self.workspaceUUID = workspaceUUID
        self.surfaceID = surfaceID
        self.workspaceName = workspaceName
        self.reason = reason
        self.request = request
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard String(describing: userInfo["event"] ?? "") == "approval_required" else { return nil }
        let workspaceID = String(describing: userInfo["workspaceID"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceUUID = String(describing: userInfo["workspaceUUID"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspaceID.isEmpty || !workspaceUUID.isEmpty else { return nil }
        self.notificationID = String(describing: userInfo["notificationID"] ?? "")
        self.workspaceID = workspaceID.isEmpty ? workspaceUUID : workspaceID
        self.workspaceUUID = workspaceUUID
        self.surfaceID = String(describing: userInfo["surfaceID"] ?? "")
        self.workspaceName = String(describing: userInfo["workspaceName"] ?? "")
        self.reason = String(describing: userInfo["reason"] ?? "")
        self.request = String(describing: userInfo["request"] ?? "")
    }
}

final class PushNotificationBridge: NSObject, ObservableObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @Published var banner: PushApprovalNotification?
    @Published var pendingDeepLink: PushApprovalNotification?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        configureNotifications(application: application)
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task {
            await registerDeviceToken(token)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        #if DEBUG
        print("[cmux] APNs registration failed: \(error.localizedDescription)")
        #endif
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if let approval = PushApprovalNotification(userInfo: notification.request.content.userInfo) {
            banner = approval
            completionHandler([.sound, .badge])
        } else {
            completionHandler([.banner, .sound, .badge])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let approval = PushApprovalNotification(userInfo: response.notification.request.content.userInfo) {
            pendingDeepLink = approval
        }
        completionHandler()
    }

    func dismissBanner() {
        banner = nil
    }

    static func clearApplicationBadge() {
        UNUserNotificationCenter.current().setBadgeCount(0) { _ in }
    }

    private func configureNotifications(application: UIApplication) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                application.registerForRemoteNotifications()
            }
        }
    }

    private func registerDeviceToken(_ token: String) async {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        do {
            _ = try await HarnessAPI.registerPushDevice(
                baseURLString: HarnessSettingsStore.serverURL,
                token: token,
                bundleID: bundleID,
                environment: environment
            )
        } catch {
            #if DEBUG
            print("[cmux] APNs token registration failed: \(error.localizedDescription)")
            #endif
        }
    }
}
