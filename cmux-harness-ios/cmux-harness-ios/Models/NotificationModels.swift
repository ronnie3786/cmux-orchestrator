import Foundation

struct CmuxNotification: Decodable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String?
    var body: String?
    var subtitle: String?
    var createdAt: String?
    var isRead: Bool
    var workspaceId: String?
    var workspaceRef: String?
    var surfaceId: String?
    var surfaceRef: String?
    var tabTitle: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case body
        case subtitle
        case createdAt = "created_at"
        case isRead = "is_read"
        case workspaceId = "workspace_id"
        case workspaceRef = "workspace_ref"
        case surfaceId = "surface_id"
        case surfaceRef = "surface_ref"
        case tabTitle = "tab_title"
    }

    var isUnread: Bool {
        !isRead
    }
}

struct NotificationsResponse: Decodable, Equatable, Sendable {
    var ok: Bool
    var notifications: [CmuxNotification]
    var error: String?

    var unreadNotifications: [CmuxNotification] {
        notifications.filter { $0.isUnread }
    }

    func unreadCount(forWorkspaceID workspaceID: String?) -> Int {
        guard let workspaceID else { return 0 }
        return notifications.count {
            $0.isUnread && $0.workspaceId == workspaceID
        }
    }

    func unreadCount(forSurfaceID surfaceID: String?) -> Int {
        guard let surfaceID else { return 0 }
        return notifications.count {
            $0.isUnread && $0.surfaceId == surfaceID
        }
    }
}
