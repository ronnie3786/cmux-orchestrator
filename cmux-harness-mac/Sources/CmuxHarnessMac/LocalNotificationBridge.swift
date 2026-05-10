import Foundation
import UserNotifications

enum LocalNotificationBridge {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
    }

    static func notifyFeedItem(_ item: FeedItem) {
        let content = UNMutableNotificationContent()
        content.title = item.displayTitle
        content.body = item.summary
        content.sound = .default
        content.userInfo = [
            "event": "feed_request",
            "requestID": item.requestID,
            "kind": item.kind
        ]

        let request = UNNotificationRequest(
            identifier: "cmux-feed-\(item.requestID)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
