import Foundation

enum SendToHerdrCommand {
    static func text(workspaceID: String, tabID: String) -> String {
        "/send-to-herdr --workspace-id \(workspaceID) --tab-id \(tabID)"
    }
}

struct HerdrTab: Codable, Equatable, Hashable, Identifiable, Sendable {
    let tabID: String
    let workspaceID: String
    let number: Int
    let label: String
    let focused: Bool
    let paneCount: Int
    let agentStatus: AgentStatus

    var machineID: String = ""

    var id: String {
        machineID.isEmpty ? tabID : MachineScopedID.compose(machineID: machineID, rawID: tabID)
    }

    func stamped(machineID: String) -> HerdrTab {
        var copy = self
        copy.machineID = machineID
        return copy
    }

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
