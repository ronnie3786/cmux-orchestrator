import AppKit
import UserNotifications

/// AppKit port of the iOS `HerdrAppDelegate`. The notification-center delegate
/// and the notification-tap → pane deep-link relay are carried over unchanged;
/// APNs device registration is deliberately absent — the Mac app is co-located
/// with the Herdr server and holds the `/api/v1/events` SSE stream open, so
/// alerts are always delivered locally.
@MainActor
final class HerdrMacAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private static var pendingPaneID: String?

    static func takePendingPaneID() -> String? {
        defer { pendingPaneID = nil }
        return pendingPaneID
    }

    nonisolated static func resolvedPaneID(fromUserInfo userInfo: [AnyHashable: Any]) -> String? {
        guard let paneID = (userInfo["pane_id"] as? String) ?? (userInfo["paneId"] as? String) else {
            return nil
        }
        if let machineID = userInfo["machine_id"] as? String, !machineID.isEmpty {
            return MachineScopedID.compose(machineID: machineID, rawID: paneID)
        }
        return paneID
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        HerdrPerfDiagnostics.start()
        VoiceRecordingPolicy.removeStaleTemporaryRecordings()
        UNUserNotificationCenter.current().delegate = self
    }

    // `UNUserNotificationCenterDelegate` is not main-actor isolated on macOS
    // (it is on iOS), so under Swift 6 these two witnesses must be nonisolated
    // and hop back to the main actor themselves.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // The active app supplies semantic feedback from agent-state changes.
        // Keep the banner visible, but do not duplicate that feedback with a
        // generic notification sound while Herdr is in the foreground.
        [.banner, .badge]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let paneID = Self.resolvedPaneID(fromUserInfo: userInfo) else { return }
        await MainActor.run {
            Self.pendingPaneID = paneID
            NotificationCenter.default.post(name: .herdrOpenPane, object: paneID)
        }
    }
}

extension Notification.Name {
    static let herdrOpenPane = Notification.Name("HerdrOpenPane")

    /// Mac-only. Posted by the View menu's "Focus Chat" / "Focus Terminal"
    /// commands with a `PaneDetailMode` as the notification object, so the
    /// mounted pane session can switch modes from the menu bar without the
    /// shell owning the pane's mode state.
    static let herdrFocusPaneMode = Notification.Name("HerdrFocusPaneMode")
}
