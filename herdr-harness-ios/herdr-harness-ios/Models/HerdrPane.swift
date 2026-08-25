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
    let firstSeenAt: Date?

    var machineID: String = ""

    var id: String {
        machineID.isEmpty ? paneID : MachineScopedID.compose(machineID: machineID, rawID: paneID)
    }

    /// The pane's parent tab id in the same machine-scoped form as `HerdrTab.id`,
    /// so pane→tab matching keeps working once entities are stamped.
    var scopedTabID: String {
        machineID.isEmpty ? tabID : MachineScopedID.compose(machineID: machineID, rawID: tabID)
    }

    func stamped(machineID: String) -> HerdrPane {
        var copy = self
        copy.machineID = machineID
        return copy
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
        case firstSeenAt = "first_seen_at"
    }

    // ISO8601DateFormatter is documented as thread-safe. These immutable
    // formatters avoid allocating one for every pane decoded from a snapshot.
    // TODO: Revisit if Foundation changes that thread-safety guarantee.
    nonisolated(unsafe) private static let withFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let withoutFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

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
        firstSeenAt = try container.decodeIfPresent(String.self, forKey: .firstSeenAt).flatMap {
            Self.withFractional.date(from: $0) ?? Self.withoutFractional.date(from: $0)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(paneID, forKey: .paneID)
        try container.encode(terminalID, forKey: .terminalID)
        try container.encode(workspaceID, forKey: .workspaceID)
        try container.encode(tabID, forKey: .tabID)
        try container.encode(focused, forKey: .focused)
        try container.encode(agentStatus, forKey: .agentStatus)
        try container.encode(revision, forKey: .revision)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(foregroundCWD, forKey: .foregroundCWD)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(agent, forKey: .agent)
        try container.encodeIfPresent(displayAgent, forKey: .displayAgent)
        try container.encodeIfPresent(terminalTitle, forKey: .terminalTitle)
        try container.encodeIfPresent(terminalTitleStripped, forKey: .terminalTitleStripped)
        try container.encode(stateLabels, forKey: .stateLabels)
        try container.encode(tokens, forKey: .tokens)
        try container.encodeIfPresent(piSemantic, forKey: .piSemantic)
        try container.encodeIfPresent(firstSeenAt.map { Self.withoutFractional.string(from: $0) }, forKey: .firstSeenAt)
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
        piSemantic: PiSemanticCapability? = nil,
        firstSeenAt: Date? = nil
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
        self.firstSeenAt = firstSeenAt
    }
}
