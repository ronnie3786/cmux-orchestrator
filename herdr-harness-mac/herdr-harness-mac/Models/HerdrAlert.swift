import Foundation

struct HerdrAlert: Decodable, Equatable, Hashable, Identifiable, Sendable {
    let rawID: String
    let workspaceID: String
    let paneID: String
    let status: AgentStatus
    let title: String
    let message: String
    let createdAt: String
    let isRead: Bool

    var machineID: String = ""

    var id: String {
        machineID.isEmpty ? rawID : MachineScopedID.compose(machineID: machineID, rawID: rawID)
    }

    var scopedPaneID: String {
        MachineScopedID.compose(machineID: machineID, rawID: paneID)
    }

    func stamped(machineID: String) -> HerdrAlert {
        var copy = self
        copy.machineID = machineID
        return copy
    }

    enum CodingKeys: String, CodingKey {
        case id
        case workspaceID = "workspace_id"
        case workspaceIDCamel = "workspaceId"
        case paneID = "pane_id"
        case paneIDCamel = "paneId"
        case status
        case kind
        case title
        case message
        case createdAt = "created_at"
        case createdAtCamel = "createdAt"
        case isRead = "is_read"
        case isReadCamel = "isRead"
        case read
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try container.decodeIfPresent(String.self, forKey: .workspaceID)
            ?? container.decodeIfPresent(String.self, forKey: .workspaceIDCamel)
            ?? ""
        paneID = try container.decodeIfPresent(String.self, forKey: .paneID)
            ?? container.decodeIfPresent(String.self, forKey: .paneIDCamel)
            ?? ""
        status = try container.decodeIfPresent(AgentStatus.self, forKey: .status)
            ?? container.decodeIfPresent(AgentStatus.self, forKey: .kind)
            ?? .unknown
        rawID = try container.decodeIfPresent(String.self, forKey: .id) ?? "\(paneID):\(status.rawValue)"
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? status.title
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
            ?? container.decodeIfPresent(String.self, forKey: .createdAtCamel)
            ?? ""
        isRead = try container.decodeIfPresent(Bool.self, forKey: .isRead)
            ?? container.decodeIfPresent(Bool.self, forKey: .isReadCamel)
            ?? container.decodeIfPresent(Bool.self, forKey: .read)
            ?? false
    }

    init(
        id: String,
        workspaceID: String,
        paneID: String,
        status: AgentStatus,
        title: String,
        message: String,
        createdAt: String,
        isRead: Bool
    ) {
        self.rawID = id
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.status = status
        self.title = title
        self.message = message
        self.createdAt = createdAt
        self.isRead = isRead
    }
}
