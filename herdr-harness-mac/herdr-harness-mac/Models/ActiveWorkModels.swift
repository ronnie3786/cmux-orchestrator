import Foundation

struct ActiveWorkResponse: Decodable, Equatable, Sendable {
    var ok: Bool
    var pipeline: ActiveWorkPipeline
    var items: [ActiveWorkItem]
    var jiraCandidates: [ActiveWorkJiraCandidate]
    var jiraCandidatesStatus: ActiveWorkSourceStatus
    var generatedAt: String?

    static let empty = ActiveWorkResponse(
        ok: true,
        pipeline: .empty,
        items: [],
        jiraCandidates: [],
        jiraCandidatesStatus: .available,
        generatedAt: nil
    )

    enum CodingKeys: String, CodingKey {
        case ok
        case pipeline
        case items
        case jiraCandidates = "jira_candidates"
        case jiraCandidatesStatus = "jira_candidates_status"
        case generatedAt = "generated_at"
    }

    init(
        ok: Bool,
        pipeline: ActiveWorkPipeline,
        items: [ActiveWorkItem],
        jiraCandidates: [ActiveWorkJiraCandidate],
        jiraCandidatesStatus: ActiveWorkSourceStatus = .available,
        generatedAt: String?
    ) {
        self.ok = ok
        self.pipeline = pipeline
        self.items = items
        self.jiraCandidates = jiraCandidates
        self.jiraCandidatesStatus = jiraCandidatesStatus
        self.generatedAt = generatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = container.flexibleBool(forKey: .ok) ?? true
        pipeline = try container.decode(ActiveWorkPipeline.self, forKey: .pipeline)
        items = (try? container.decode([ActiveWorkItem].self, forKey: .items)) ?? []
        jiraCandidates = (try? container.decode([ActiveWorkJiraCandidate].self, forKey: .jiraCandidates)) ?? []
        jiraCandidatesStatus = (try? container.decode(ActiveWorkSourceStatus.self, forKey: .jiraCandidatesStatus)) ?? .available
        generatedAt = container.flexibleString(forKey: .generatedAt)
    }
}

struct ActiveWorkSourceStatus: Decodable, Equatable, Sendable {
    var ok: Bool
    var error: String?

    static let available = ActiveWorkSourceStatus(ok: true, error: nil)

    enum CodingKeys: String, CodingKey {
        case ok
        case error
    }

    init(ok: Bool, error: String?) {
        self.ok = ok
        self.error = error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = container.flexibleBool(forKey: .ok) ?? true
        error = container.flexibleString(forKey: .error)
    }
}

struct ActiveWorkPipeline: Decodable, Equatable, Sendable {
    var id: String
    var slug: String
    var version: Int
    var title: String
    var stages: [ActiveWorkPipelineStage]

    static let empty = ActiveWorkPipeline(id: "", slug: "", version: 0, title: "Active Work", stages: [])

    enum CodingKeys: String, CodingKey {
        case id
        case slug
        case version
        case title
        case stages
    }

    init(id: String, slug: String, version: Int, title: String, stages: [ActiveWorkPipelineStage]) {
        self.id = id
        self.slug = slug
        self.version = version
        self.title = title
        self.stages = stages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.flexibleString(forKey: .id) ?? ""
        slug = container.flexibleString(forKey: .slug) ?? ""
        version = container.flexibleInt(forKey: .version) ?? 0
        title = container.flexibleString(forKey: .title) ?? "Active Work"
        stages = (try? container.decode([ActiveWorkPipelineStage].self, forKey: .stages)) ?? []
    }
}

struct ActiveWorkPipelineStage: Decodable, Equatable, Hashable, Identifiable, Sendable {
    var id: String
    var key: String
    var sequence: Int
    var phase: String
    var title: String
    var shortTitle: String
    var skillName: String?
    var checkpoint: String?

    enum CodingKeys: String, CodingKey {
        case id
        case key
        case stageKey = "stage_key"
        case sequence
        case phase
        case phaseKey = "phase_key"
        case title
        case shortTitle = "short_title"
        case skillName = "skill_name"
        case checkpoint
        case checkpointKind = "checkpoint_kind"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedKey = container.flexibleString(forKey: .key)
            ?? container.flexibleString(forKey: .stageKey)
            ?? ""
        key = decodedKey
        id = container.flexibleString(forKey: .id) ?? decodedKey
        sequence = container.flexibleInt(forKey: .sequence) ?? 0
        phase = container.flexibleString(forKey: .phase)
            ?? container.flexibleString(forKey: .phaseKey)
            ?? ""
        title = container.flexibleString(forKey: .title) ?? decodedKey.displayNameFromIdentifier
        shortTitle = container.flexibleString(forKey: .shortTitle) ?? title
        skillName = container.flexibleString(forKey: .skillName)
        checkpoint = container.flexibleString(forKey: .checkpoint)
            ?? container.flexibleString(forKey: .checkpointKind)
    }
}

struct ActiveWorkItem: Decodable, Equatable, Identifiable, Sendable {
    var id: String
    var kind: String
    var title: String
    var summary: String
    var lifecycle: String
    var currentStageKey: String?
    var nextAction: String?
    var revision: Int
    var needsAttention: Bool
    var attentionReason: String?
    var setupState: String?
    var createdAt: String?
    var updatedAt: String?
    var archivedAt: String?
    var jiraLinks: [ActiveWorkJiraLink]
    var buzzChannels: [ActiveWorkBuzzChannel]
    var stages: [ActiveWorkStageState]
    var agents: [ActiveWorkAgent]
    var piSessions: [ActiveWorkPiSession]
    var threads: [ActiveWorkThread]
    var activity: [ActiveWorkActivity]

    var jira: ActiveWorkJiraLink? { jiraLinks.first }
    var buzzChannel: ActiveWorkBuzzChannel? { buzzChannels.first }
    var updatedDate: Date? { updatedAt.flatMap(HerdrTimestamp.date(from:)) }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case summary
        case lifecycle
        case currentStageKey = "current_stage_key"
        case nextAction = "next_action"
        case revision
        case needsAttention = "needs_attention"
        case attentionReason = "attention_reason"
        case setupState = "setup_state"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case archivedAt = "archived_at"
        case jira
        case jiraLinks = "jira_links"
        case buzzChannel = "buzz_channel"
        case buzzChannels = "buzz_channels"
        case stages
        case agents
        case piSessions = "pi_sessions"
        case threads
        case unscopedThreads = "unscoped_threads"
        case activity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.flexibleString(forKey: .id) ?? ""
        kind = container.flexibleString(forKey: .kind) ?? "work"
        title = container.flexibleString(forKey: .title) ?? "Untitled work"
        summary = container.flexibleString(forKey: .summary) ?? ""
        lifecycle = container.flexibleString(forKey: .lifecycle) ?? "active"
        currentStageKey = container.flexibleString(forKey: .currentStageKey)
        nextAction = container.flexibleString(forKey: .nextAction)
        revision = container.flexibleInt(forKey: .revision) ?? 0
        needsAttention = container.flexibleBool(forKey: .needsAttention) ?? false
        attentionReason = container.flexibleString(forKey: .attentionReason)
        setupState = container.flexibleString(forKey: .setupState)
        createdAt = container.flexibleString(forKey: .createdAt)
        updatedAt = container.flexibleString(forKey: .updatedAt)
        archivedAt = container.flexibleString(forKey: .archivedAt)

        jiraLinks = (try? container.decode([ActiveWorkJiraLink].self, forKey: .jiraLinks)) ?? []
        if let singular = try? container.decode(ActiveWorkJiraLink.self, forKey: .jira),
           !jiraLinks.contains(where: { $0.id == singular.id }) {
            jiraLinks.insert(singular, at: 0)
        }

        buzzChannels = (try? container.decode([ActiveWorkBuzzChannel].self, forKey: .buzzChannels)) ?? []
        if let singular = try? container.decode(ActiveWorkBuzzChannel.self, forKey: .buzzChannel),
           !buzzChannels.contains(where: { $0.id == singular.id }) {
            buzzChannels.insert(singular, at: 0)
        }

        stages = (try? container.decode([ActiveWorkStageState].self, forKey: .stages)) ?? []
        agents = (try? container.decode([ActiveWorkAgent].self, forKey: .agents)) ?? []
        piSessions = (try? container.decode([ActiveWorkPiSession].self, forKey: .piSessions)) ?? []
        let directThreads = (try? container.decode([ActiveWorkThread].self, forKey: .threads)) ?? []
        let unscopedThreads = (try? container.decode([ActiveWorkThread].self, forKey: .unscopedThreads)) ?? []
        var seenThreadIDs = Set<String>()
        threads = (directThreads + unscopedThreads).filter { seenThreadIDs.insert($0.id).inserted }
        activity = (try? container.decode([ActiveWorkActivity].self, forKey: .activity)) ?? []
    }
}

struct ActiveWorkStageState: Decodable, Equatable, Identifiable, Sendable {
    var id: String
    var stageKey: String
    var state: ActiveWorkStageProgress
    var attention: ActiveWorkStageAttention
    var checkpointState: String?
    var summary: String
    var sourceObservedAt: String?
    var startedAt: String?
    var completedAt: String?
    var updatedAt: String?
    var agents: [ActiveWorkAgent]
    var piSessions: [ActiveWorkPiSession]
    var threads: [ActiveWorkThread]

    enum CodingKeys: String, CodingKey {
        case id
        case stageKey = "stage_key"
        case state
        case attention
        case checkpointState = "checkpoint_state"
        case summary
        case sourceObservedAt = "source_observed_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case updatedAt = "updated_at"
        case agents
        case piSessions = "pi_sessions"
        case threads
        case buzzThreads = "buzz_threads"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stageKey = container.flexibleString(forKey: .stageKey) ?? ""
        id = container.flexibleString(forKey: .id) ?? stageKey
        state = ActiveWorkStageProgress(rawValue: container.flexibleString(forKey: .state) ?? "unknown")
        attention = ActiveWorkStageAttention(
            rawValue: container.flexibleString(forKey: .attention)
                ?? ((container.flexibleBool(forKey: .attention) ?? false) ? "human" : "none")
        )
        checkpointState = container.flexibleString(forKey: .checkpointState)
        summary = container.flexibleString(forKey: .summary) ?? ""
        sourceObservedAt = container.flexibleString(forKey: .sourceObservedAt)
        startedAt = container.flexibleString(forKey: .startedAt)
        completedAt = container.flexibleString(forKey: .completedAt)
        updatedAt = container.flexibleString(forKey: .updatedAt)
        agents = (try? container.decode([ActiveWorkAgent].self, forKey: .agents)) ?? []
        piSessions = (try? container.decode([ActiveWorkPiSession].self, forKey: .piSessions)) ?? []
        threads = (try? container.decode([ActiveWorkThread].self, forKey: .threads))
            ?? (try? container.decode([ActiveWorkThread].self, forKey: .buzzThreads))
            ?? []
    }
}

enum ActiveWorkStageProgress: Equatable, Hashable, Sendable {
    case pending
    case active
    case complete
    case blocked
    case skipped
    case unknown

    init(rawValue: String) {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pending", "queued", "not_started", "not-started": self = .pending
        case "ready": self = .pending
        case "active", "current", "in_progress", "in-progress", "working": self = .active
        case "complete", "completed", "done", "passed": self = .complete
        case "blocked", "failed", "needs_attention", "needs-attention": self = .blocked
        case "skipped", "not_applicable", "not-applicable": self = .skipped
        default: self = .unknown
        }
    }
}

enum ActiveWorkStageAttention: Equatable, Hashable, Sendable {
    case none
    case agent
    case human
    case unknown

    init(rawValue: String) {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "none", "false", "0", "no": self = .none
        case "agent": self = .agent
        case "human", "true", "1", "yes": self = .human
        default: self = .unknown
        }
    }
}

struct ActiveWorkAgent: Decodable, Equatable, Identifiable, Sendable {
    var id: String
    var source: String?
    var externalID: String?
    var displayName: String
    var kind: String?
    var roleLabel: String?
    var avatarKey: String?
    var avatarURL: String?
    var status: AgentStatus
    var stageKey: String?
    var paneID: String?
    var linkRole: String?
    var linkState: String?
    var lastSeenAt: String?
    var attachedAt: String?
    var detachedAt: String?
    var stageLinks: [ActiveWorkAgentStageLink]

    var initials: String {
        let parts = displayName.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
        let value = parts.prefix(2).compactMap(\.first).map(String.init).joined()
        return value.isEmpty ? "AI" : value.uppercased()
    }

    var remoteAvatarURL: URL? {
        guard let avatarURL,
              let candidate = URL(string: avatarURL),
              candidate.scheme?.lowercased() == "https" else { return nil }
        return candidate
    }

    enum CodingKeys: String, CodingKey {
        case id
        case source
        case externalID = "external_id"
        case displayName = "display_name"
        case name
        case kind
        case roleLabel = "role_label"
        case role
        case avatarKey = "avatar_key"
        case avatarURL = "avatar_url"
        case status
        case stageKey = "stage_key"
        case paneID = "pane_id"
        case linkRole = "link_role"
        case linkState = "link_state"
        case lastSeenAt = "last_seen_at"
        case attachedAt = "attached_at"
        case detachedAt = "detached_at"
        case stageLinks = "stage_links"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.flexibleString(forKey: .id)
            ?? container.flexibleString(forKey: .externalID)
            ?? UUID().uuidString
        source = container.flexibleString(forKey: .source)
        externalID = container.flexibleString(forKey: .externalID)
        displayName = container.flexibleString(forKey: .displayName)
            ?? container.flexibleString(forKey: .name)
            ?? container.flexibleString(forKey: .kind)?.displayNameFromIdentifier
            ?? "Agent"
        kind = container.flexibleString(forKey: .kind)
        roleLabel = container.flexibleString(forKey: .roleLabel) ?? container.flexibleString(forKey: .role)
        avatarKey = container.flexibleString(forKey: .avatarKey)
        avatarURL = container.flexibleString(forKey: .avatarURL)
        status = AgentStatus.activeWorkStatus(from: container.flexibleString(forKey: .status))
        stageKey = container.flexibleString(forKey: .stageKey)
        paneID = container.flexibleString(forKey: .paneID)
        linkRole = container.flexibleString(forKey: .linkRole)
        linkState = container.flexibleString(forKey: .linkState)
        lastSeenAt = container.flexibleString(forKey: .lastSeenAt)
        attachedAt = container.flexibleString(forKey: .attachedAt)
        detachedAt = container.flexibleString(forKey: .detachedAt)
        stageLinks = (try? container.decode([ActiveWorkAgentStageLink].self, forKey: .stageLinks)) ?? []
    }
}

struct ActiveWorkAgentStageLink: Decodable, Equatable, Sendable {
    var stageKey: String
    var linkRole: String?
    var linkState: String?
    var attachedAt: String?
    var detachedAt: String?

    enum CodingKeys: String, CodingKey {
        case stageKey = "stage_key"
        case linkRole = "link_role"
        case linkState = "link_state"
        case attachedAt = "attached_at"
        case detachedAt = "detached_at"
    }
}

struct ActiveWorkPiSession: Decodable, Equatable, Identifiable, Sendable {
    var id: String
    var source: String?
    var externalID: String?
    var agentID: String?
    var title: String
    var provider: String?
    var model: String?
    var status: String
    var machineID: String?
    var workspaceID: String?
    var paneID: String?
    var nativeSessionID: String?
    var stageKey: String?
    var linkRole: String?
    var startedAt: String?
    var lastSeenAt: String?
    var endedAt: String?
    var attachedAt: String?
    var detachedAt: String?
    var stageLinks: [ActiveWorkPiSessionStageLink]

    enum CodingKeys: String, CodingKey {
        case id
        case source
        case externalID = "external_id"
        case agentID = "agent_id"
        case title
        case provider
        case model
        case status
        case machineID = "machine_id"
        case workspaceID = "workspace_id"
        case paneID = "pane_id"
        case nativeSessionID = "native_session_id"
        case stageKey = "stage_key"
        case linkRole = "link_role"
        case startedAt = "started_at"
        case lastSeenAt = "last_seen_at"
        case endedAt = "ended_at"
        case attachedAt = "attached_at"
        case detachedAt = "detached_at"
        case stageLinks = "stage_links"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.flexibleString(forKey: .id)
            ?? container.flexibleString(forKey: .externalID)
            ?? UUID().uuidString
        source = container.flexibleString(forKey: .source)
        externalID = container.flexibleString(forKey: .externalID)
        agentID = container.flexibleString(forKey: .agentID)
        title = container.flexibleString(forKey: .title) ?? "Pi session"
        provider = container.flexibleString(forKey: .provider)
        model = container.flexibleString(forKey: .model)
        status = container.flexibleString(forKey: .status) ?? "unknown"
        machineID = container.flexibleString(forKey: .machineID)
        workspaceID = container.flexibleString(forKey: .workspaceID)
        paneID = container.flexibleString(forKey: .paneID)
        nativeSessionID = container.flexibleString(forKey: .nativeSessionID)
        stageKey = container.flexibleString(forKey: .stageKey)
        linkRole = container.flexibleString(forKey: .linkRole)
        startedAt = container.flexibleString(forKey: .startedAt)
        lastSeenAt = container.flexibleString(forKey: .lastSeenAt)
        endedAt = container.flexibleString(forKey: .endedAt)
        attachedAt = container.flexibleString(forKey: .attachedAt)
        detachedAt = container.flexibleString(forKey: .detachedAt)
        stageLinks = (try? container.decode([ActiveWorkPiSessionStageLink].self, forKey: .stageLinks)) ?? []
    }
}

struct ActiveWorkPiSessionStageLink: Decodable, Equatable, Sendable {
    var stageKey: String
    var linkRole: String?
    var attachedAt: String?
    var detachedAt: String?

    enum CodingKeys: String, CodingKey {
        case stageKey = "stage_key"
        case linkRole = "link_role"
        case attachedAt = "attached_at"
        case detachedAt = "detached_at"
    }
}

struct ActiveWorkThread: Decodable, Equatable, Identifiable, Sendable {
    var id: String
    var channelID: String?
    var stageID: String?
    var stageKey: String?
    var source: String?
    var externalID: String?
    var title: String
    var url: String?
    var snippet: String?
    var status: String
    var paneID: String?
    var lastActivityAt: String?
    var updatedAt: String?

    var browserURL: URL? {
        guard let url,
              let candidate = URL(string: url),
              let scheme = candidate.scheme?.lowercased(),
              ["http", "https", "buzz"].contains(scheme) else { return nil }
        return candidate
    }

    enum CodingKeys: String, CodingKey {
        case id
        case channelID = "channel_id"
        case stageID = "stage_id"
        case stageKey = "stage_key"
        case source
        case externalID = "external_id"
        case title
        case url
        case snippet
        case status
        case paneID = "pane_id"
        case lastActivityAt = "last_activity_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.flexibleString(forKey: .id)
            ?? container.flexibleString(forKey: .externalID)
            ?? UUID().uuidString
        channelID = container.flexibleString(forKey: .channelID)
        stageID = container.flexibleString(forKey: .stageID)
        stageKey = container.flexibleString(forKey: .stageKey)
        source = container.flexibleString(forKey: .source)
        externalID = container.flexibleString(forKey: .externalID)
        title = container.flexibleString(forKey: .title) ?? "Buzz thread"
        url = container.flexibleString(forKey: .url)
        snippet = container.flexibleString(forKey: .snippet)
        status = container.flexibleString(forKey: .status) ?? "unknown"
        paneID = container.flexibleString(forKey: .paneID)
        lastActivityAt = container.flexibleString(forKey: .lastActivityAt)
        updatedAt = container.flexibleString(forKey: .updatedAt)
    }
}

struct ActiveWorkActivity: Decodable, Equatable, Identifiable, Sendable {
    var id: String
    var stageID: String?
    var stageKey: String?
    var kind: String
    var actorKind: String?
    var actorID: String?
    var message: String
    var source: String?
    var sourceEventID: String?
    var occurredAt: String?
    var createdAt: String?

    var eventDate: Date? {
        (occurredAt ?? createdAt).flatMap(HerdrTimestamp.date(from:))
    }

    enum CodingKeys: String, CodingKey {
        case id
        case stageID = "stage_id"
        case stageKey = "stage_key"
        case kind
        case actorKind = "actor_kind"
        case actorID = "actor_id"
        case message
        case title
        case source
        case sourceEventID = "source_event_id"
        case occurredAt = "occurred_at"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.flexibleString(forKey: .id)
            ?? container.flexibleString(forKey: .sourceEventID)
            ?? UUID().uuidString
        stageID = container.flexibleString(forKey: .stageID)
        stageKey = container.flexibleString(forKey: .stageKey)
        kind = container.flexibleString(forKey: .kind) ?? "update"
        actorKind = container.flexibleString(forKey: .actorKind)
        actorID = container.flexibleString(forKey: .actorID)
        message = container.flexibleString(forKey: .message)
            ?? container.flexibleString(forKey: .title)
            ?? "Work updated"
        source = container.flexibleString(forKey: .source)
        sourceEventID = container.flexibleString(forKey: .sourceEventID)
        occurredAt = container.flexibleString(forKey: .occurredAt)
        createdAt = container.flexibleString(forKey: .createdAt)
    }
}

struct ActiveWorkJiraLink: Decodable, Equatable, Identifiable, Sendable {
    var id: String
    var site: String?
    var issueKey: String
    var title: String
    var status: String
    var priority: String?
    var issueType: String?
    var url: String?
    var observedAt: String?
    var updatedAt: String?

    var browserURL: URL? { ActiveWorkURL.webURL(from: url) }

    enum CodingKeys: String, CodingKey {
        case id
        case site
        case issueKey = "issue_key"
        case key
        case title
        case status
        case priority
        case issueType = "issue_type"
        case url
        case observedAt = "observed_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        issueKey = container.flexibleString(forKey: .issueKey)
            ?? container.flexibleString(forKey: .key)
            ?? ""
        id = container.flexibleString(forKey: .id) ?? issueKey
        site = container.flexibleString(forKey: .site)
        title = container.flexibleString(forKey: .title) ?? issueKey
        status = container.flexibleString(forKey: .status) ?? "Unknown"
        priority = container.flexibleString(forKey: .priority)
        issueType = container.flexibleString(forKey: .issueType)
        url = container.flexibleString(forKey: .url)
        observedAt = container.flexibleString(forKey: .observedAt)
        updatedAt = container.flexibleString(forKey: .updatedAt)
    }
}

struct ActiveWorkBuzzChannel: Decodable, Equatable, Identifiable, Sendable {
    var id: String
    var source: String?
    var externalID: String?
    var name: String
    var url: String?
    var status: String
    var lastActivityAt: String?
    var updatedAt: String?

    var browserURL: URL? { ActiveWorkURL.webURL(from: url) }

    enum CodingKeys: String, CodingKey {
        case id
        case source
        case externalID = "external_id"
        case name
        case title
        case url
        case status
        case lastActivityAt = "last_activity_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.flexibleString(forKey: .id)
            ?? container.flexibleString(forKey: .externalID)
            ?? UUID().uuidString
        source = container.flexibleString(forKey: .source)
        externalID = container.flexibleString(forKey: .externalID)
        name = container.flexibleString(forKey: .name)
            ?? container.flexibleString(forKey: .title)
            ?? "Buzz"
        url = container.flexibleString(forKey: .url)
        status = container.flexibleString(forKey: .status) ?? "active"
        lastActivityAt = container.flexibleString(forKey: .lastActivityAt)
        updatedAt = container.flexibleString(forKey: .updatedAt)
    }
}

struct ActiveWorkJiraCandidate: Decodable, Equatable, Identifiable, Sendable {
    var key: String
    var title: String
    var status: String
    var priority: String?
    var issueType: String?
    var url: String?
    var setupState: ActiveWorkJiraSetupState
    var workItemID: String?

    var id: String { key }
    var browserURL: URL? { ActiveWorkURL.webURL(from: url) }

    enum CodingKeys: String, CodingKey {
        case key
        case title
        case status
        case priority
        case issueType = "issue_type"
        case url
        case setupState = "setup_state"
        case workItemID = "work_item_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = container.flexibleString(forKey: .key) ?? ""
        title = container.flexibleString(forKey: .title) ?? key
        status = container.flexibleString(forKey: .status) ?? "Unknown"
        priority = container.flexibleString(forKey: .priority)
        issueType = container.flexibleString(forKey: .issueType)
        url = container.flexibleString(forKey: .url)
        setupState = ActiveWorkJiraSetupState(rawValue: container.flexibleString(forKey: .setupState) ?? "available")
        workItemID = container.flexibleString(forKey: .workItemID)
    }
}

enum ActiveWorkJiraSetupState: Equatable, Hashable, Sendable {
    case available
    case settingUp
    case onBoard
    case unavailable

    init(rawValue: String) {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "setting_up", "setting-up", "creating", "in_progress", "in-progress": self = .settingUp
        case "on_board", "on-board", "configured", "complete", "completed", "ready", "board_created", "channel_linked": self = .onBoard
        case "unavailable", "disabled", "unsupported": self = .unavailable
        default: self = .available
        }
    }
}

enum ActiveWorkReadiness: Equatable, Sendable {
    case buzzSetupNext
    case driverSetupNext
    case ready

    var title: String {
        switch self {
        case .buzzSetupNext: "Buzz setup next"
        case .driverSetupNext: "Driver setup next"
        case .ready: "Ready"
        }
    }
}

extension ActiveWorkItem {
    var readiness: ActiveWorkReadiness {
        switch setupState?.lowercased() {
        case "board_created": return .buzzSetupNext
        case "channel_linked": return .driverSetupNext
        case "ready": return .ready
        default: break
        }

        let hasActiveChannel = buzzChannels.contains { channel in
            !["inactive", "archived", "closed", "disabled"].contains(channel.status.lowercased())
        }
        guard hasActiveChannel else { return .buzzSetupNext }
        let linkedAgents = agents + stages.flatMap(\.agents)
        let hasDedicatedDriver = linkedAgents.contains { agent in
            let directRole = agent.detachedAt == nil && agent.linkRole?.lowercased() == "driver"
            let linkedRole = agent.stageLinks.contains { link in
                link.detachedAt == nil && link.linkRole?.lowercased() == "driver"
            }
            return directRole || linkedRole
        }
        return hasDedicatedDriver ? .ready : .driverSetupNext
    }
}

private enum ActiveWorkURL {
    static func webURL(from value: String?) -> URL? {
        guard let value,
              let candidate = URL(string: value),
              let scheme = candidate.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else { return nil }
        return candidate
    }
}

private extension AgentStatus {
    static func activeWorkStatus(from rawValue: String?) -> AgentStatus {
        switch rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "blocked", "failed", "needs_attention", "needs-attention": .blocked
        case "done", "complete", "completed", "ready": .done
        case "working", "active", "running", "in_progress", "in-progress": .working
        case "idle", "waiting", "available": .idle
        default: .unknown
        }
    }
}

private extension String {
    var displayNameFromIdentifier: String {
        replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

private extension KeyedDecodingContainer {
    func flexibleString(forKey key: Key) -> String? {
        if let value = try? decode(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = try? decode(Int.self, forKey: key) { return String(value) }
        if let value = try? decode(Double.self, forKey: key) { return String(value) }
        if let value = try? decode(Bool.self, forKey: key) { return value ? "true" : "false" }
        return nil
    }

    func flexibleInt(forKey key: Key) -> Int? {
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = try? decode(Double.self, forKey: key) { return Int(value) }
        if let value = try? decode(String.self, forKey: key) { return Int(value) }
        return nil
    }

    func flexibleBool(forKey key: Key) -> Bool? {
        if let value = try? decode(Bool.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return value != 0 }
        if let value = try? decode(String.self, forKey: key) {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes", "agent", "human": return true
            case "false", "0", "no", "none": return false
            default: return nil
            }
        }
        return nil
    }
}
