import Foundation

struct HerdrAgent: Codable, Equatable, Hashable, Identifiable, Sendable {
    let terminalID: String
    let workspaceID: String
    let tabID: String
    let paneID: String
    let focused: Bool
    let agentStatus: AgentStatus
    let revision: Int
    let stateChangeSequence: Int
    let agent: String?
    let displayAgent: String?
    let name: String?
    let title: String?
    let cwd: String?
    let foregroundCWD: String?
    let interactiveReady: Bool

    var id: String { paneID }

    enum CodingKeys: String, CodingKey {
        case terminalID = "terminal_id"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case paneID = "pane_id"
        case focused
        case agentStatus = "agent_status"
        case revision
        case stateChangeSequence = "state_change_seq"
        case agent
        case displayAgent = "display_agent"
        case name
        case title
        case cwd
        case foregroundCWD = "foreground_cwd"
        case interactiveReady = "interactive_ready"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        terminalID = try container.decode(String.self, forKey: .terminalID)
        workspaceID = try container.decode(String.self, forKey: .workspaceID)
        tabID = try container.decode(String.self, forKey: .tabID)
        paneID = try container.decode(String.self, forKey: .paneID)
        focused = try container.decodeIfPresent(Bool.self, forKey: .focused) ?? false
        agentStatus = try container.decodeIfPresent(AgentStatus.self, forKey: .agentStatus) ?? .unknown
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        stateChangeSequence = try container.decodeIfPresent(Int.self, forKey: .stateChangeSequence) ?? 0
        agent = try container.decodeIfPresent(String.self, forKey: .agent)
        displayAgent = try container.decodeIfPresent(String.self, forKey: .displayAgent)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        foregroundCWD = try container.decodeIfPresent(String.self, forKey: .foregroundCWD)
        interactiveReady = try container.decodeIfPresent(Bool.self, forKey: .interactiveReady) ?? false
    }
}
