import Foundation

struct HerdrWorkspace: Codable, Equatable, Hashable, Identifiable, Sendable {
    let workspaceID: String
    let number: Int
    let label: String
    let focused: Bool
    let paneCount: Int
    let tabCount: Int
    let activeTabID: String
    let agentStatus: AgentStatus
    let tokens: [String: String]
    let worktree: HerdrWorktree?
    let tabs: [HerdrTab]
    let panes: [HerdrPane]
    let agents: [HerdrAgent]
    let layouts: [HerdrLayout]

    var id: String { workspaceID }

    var displayPath: String {
        if let worktree { return worktree.checkoutPath }
        return panes.compactMap(\.foregroundCWD).first ?? panes.compactMap(\.cwd).first ?? ""
    }

    var sortedPanes: [HerdrPane] {
        panes.sorted {
            if $0.agentStatus.attentionRank != $1.agentStatus.attentionRank {
                return $0.agentStatus.attentionRank < $1.agentStatus.attentionRank
            }
            if $0.tabID != $1.tabID { return $0.tabID < $1.tabID }
            return $0.paneID < $1.paneID
        }
    }

    var attentionCount: Int { panes.count(where: { $0.agentStatus.needsAttention }) }
    var workingCount: Int { panes.count(where: { $0.agentStatus == .working }) }

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case number
        case label
        case focused
        case paneCount = "pane_count"
        case tabCount = "tab_count"
        case activeTabID = "active_tab_id"
        case agentStatus = "agent_status"
        case tokens
        case worktree
        case tabs
        case panes
        case agents
        case layouts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try container.decode(String.self, forKey: .workspaceID)
        number = try container.decodeIfPresent(Int.self, forKey: .number) ?? 0
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? workspaceID
        focused = try container.decodeIfPresent(Bool.self, forKey: .focused) ?? false
        paneCount = try container.decodeIfPresent(Int.self, forKey: .paneCount) ?? 0
        tabCount = try container.decodeIfPresent(Int.self, forKey: .tabCount) ?? 0
        activeTabID = try container.decodeIfPresent(String.self, forKey: .activeTabID) ?? ""
        agentStatus = try container.decodeIfPresent(AgentStatus.self, forKey: .agentStatus) ?? .unknown
        tokens = try container.decodeIfPresent([String: String].self, forKey: .tokens) ?? [:]
        worktree = try container.decodeIfPresent(HerdrWorktree.self, forKey: .worktree)
        tabs = try container.decodeIfPresent([HerdrTab].self, forKey: .tabs) ?? []
        panes = try container.decodeIfPresent([HerdrPane].self, forKey: .panes) ?? []
        agents = try container.decodeIfPresent([HerdrAgent].self, forKey: .agents) ?? []
        layouts = try container.decodeIfPresent([HerdrLayout].self, forKey: .layouts) ?? []
    }

    init(
        workspaceID: String,
        number: Int,
        label: String,
        focused: Bool,
        paneCount: Int,
        tabCount: Int,
        activeTabID: String,
        agentStatus: AgentStatus,
        tokens: [String: String] = [:],
        worktree: HerdrWorktree? = nil,
        tabs: [HerdrTab] = [],
        panes: [HerdrPane] = [],
        agents: [HerdrAgent] = [],
        layouts: [HerdrLayout] = []
    ) {
        self.workspaceID = workspaceID
        self.number = number
        self.label = label
        self.focused = focused
        self.paneCount = paneCount
        self.tabCount = tabCount
        self.activeTabID = activeTabID
        self.agentStatus = agentStatus
        self.tokens = tokens
        self.worktree = worktree
        self.tabs = tabs
        self.panes = panes
        self.agents = agents
        self.layouts = layouts
    }
}
