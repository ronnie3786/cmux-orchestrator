import Foundation

struct HerdrPane: Codable, Equatable, Hashable, Identifiable, Sendable {
    let paneID: String
    let terminalID: String
    let workspaceID: String
    let tabID: String
    let focused: Bool
    let agentStatus: AgentStatus
    let revision: Int
    let cwd: String?
    let foregroundCWD: String?
    let label: String?
    let title: String?
    let agent: String?
    let displayAgent: String?
    let terminalTitle: String?
    let terminalTitleStripped: String?
    let stateLabels: [String: String]
    let tokens: [String: String]
    let piSemantic: PiSemanticCapability?

    var machineID: String = ""
    private(set) var id: String
    private(set) var scopedTabID: String

    func stamped(machineID: String) -> HerdrPane {
        var copy = self
        copy.machineID = machineID
        copy.id = MachineScopedID.compose(machineID: machineID, rawID: paneID)
        copy.scopedTabID = MachineScopedID.compose(machineID: machineID, rawID: tabID)
        return copy
    }

    func isEqualIgnoringRevision(to other: HerdrPane) -> Bool {
        paneID == other.paneID
            && terminalID == other.terminalID
            && workspaceID == other.workspaceID
            && tabID == other.tabID
            && focused == other.focused
            && agentStatus == other.agentStatus
            && cwd == other.cwd
            && foregroundCWD == other.foregroundCWD
            && label == other.label
            && title == other.title
            && agent == other.agent
            && displayAgent == other.displayAgent
            && terminalTitle == other.terminalTitle
            && terminalTitleStripped == other.terminalTitleStripped
            && stateLabels == other.stateLabels
            && tokens == other.tokens
            && piSemantic == other.piSemantic
            && machineID == other.machineID
            && id == other.id
            && scopedTabID == other.scopedTabID
    }

    var displayTitle: String {
        for candidate in [label, title, terminalTitleStripped, displayAgent, agent] {
            if let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return candidate
            }
        }
        let suffix = paneID.split(separator: "p").last.map(String.init) ?? paneID
        return "Pane \(suffix)"
    }

    var displayAgentName: String {
        displayAgent ?? agent ?? (agentStatus == .unknown ? "Terminal" : "Agent")
    }

    var displayPath: String {
        foregroundCWD ?? cwd ?? ""
    }

    var supportsPiSemanticChat: Bool {
        piSemantic?.available == true && piSemantic?.protocolVersion == 1
    }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case terminalID = "terminal_id"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case focused
        case agentStatus = "agent_status"
        case revision
        case cwd
        case foregroundCWD = "foreground_cwd"
        case label
        case title
        case agent
        case displayAgent = "display_agent"
        case terminalTitle = "terminal_title"
        case terminalTitleStripped = "terminal_title_stripped"
        case stateLabels = "state_labels"
        case tokens
        case piSemantic = "pi_semantic"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paneID = try container.decode(String.self, forKey: .paneID)
        terminalID = try container.decodeIfPresent(String.self, forKey: .terminalID) ?? paneID
        workspaceID = try container.decode(String.self, forKey: .workspaceID)
        tabID = try container.decode(String.self, forKey: .tabID)
        focused = try container.decodeIfPresent(Bool.self, forKey: .focused) ?? false
        agentStatus = try container.decodeIfPresent(AgentStatus.self, forKey: .agentStatus) ?? .unknown
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        foregroundCWD = try container.decodeIfPresent(String.self, forKey: .foregroundCWD)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        agent = try container.decodeIfPresent(String.self, forKey: .agent)
        displayAgent = try container.decodeIfPresent(String.self, forKey: .displayAgent)
        terminalTitle = try container.decodeIfPresent(String.self, forKey: .terminalTitle)
        terminalTitleStripped = try container.decodeIfPresent(String.self, forKey: .terminalTitleStripped)
        stateLabels = try container.decodeIfPresent([String: String].self, forKey: .stateLabels) ?? [:]
        tokens = try container.decodeIfPresent([String: String].self, forKey: .tokens) ?? [:]
        piSemantic = try container.decodeIfPresent(PiSemanticCapability.self, forKey: .piSemantic)
        id = paneID
        scopedTabID = tabID
    }

    init(
        paneID: String,
        terminalID: String,
        workspaceID: String,
        tabID: String,
        focused: Bool,
        agentStatus: AgentStatus,
        revision: Int,
        cwd: String?,
        foregroundCWD: String?,
        label: String?,
        title: String?,
        agent: String?,
        displayAgent: String?,
        terminalTitle: String?,
        terminalTitleStripped: String?,
        stateLabels: [String: String] = [:],
        tokens: [String: String] = [:],
        piSemantic: PiSemanticCapability? = nil
    ) {
        self.paneID = paneID
        self.terminalID = terminalID
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.focused = focused
        self.agentStatus = agentStatus
        self.revision = revision
        self.cwd = cwd
        self.foregroundCWD = foregroundCWD
        self.label = label
        self.title = title
        self.agent = agent
        self.displayAgent = displayAgent
        self.terminalTitle = terminalTitle
        self.terminalTitleStripped = terminalTitleStripped
        self.stateLabels = stateLabels
        self.tokens = tokens
        self.piSemantic = piSemantic
        self.id = paneID
        self.scopedTabID = tabID
    }
}
