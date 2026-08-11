import Foundation

struct HerdrTab: Codable, Equatable, Hashable, Identifiable, Sendable {
    let tabID: String
    let workspaceID: String
    let number: Int
    let label: String
    let focused: Bool
    let paneCount: Int
    let agentStatus: AgentStatus

    var id: String { tabID }

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case workspaceID = "workspace_id"
        case number
        case label
        case focused
        case paneCount = "pane_count"
        case agentStatus = "agent_status"
    }
}
