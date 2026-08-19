import ComposableArchitecture
import Foundation

enum QuickSessionCreationPhase: Equatable, Sendable {
    case creating
    case switching
}

struct QuickSessionCreation: Equatable, Sendable {
    var workspaceID: String
    var directoryPath: String
    var phase: QuickSessionCreationPhase
}

struct PendingCreatedWorkspaceSelection: Equatable, Sendable {
    var uuid: String?
    var index: Int?
}

@Reducer
struct HarnessFeature {
    @Dependency(\.continuousClock) var clock
    @Dependency(\.date.now) var now
    @Dependency(\.harnessClient) var harnessClient
    @Dependency(\.uuid) var uuid

    @ObservableState
    struct State: Equatable {
        var serverSources: [HarnessServerSource] = HarnessSettingsStore.serverSources
        var selectedServerSourceID = HarnessSettingsStore.selectedServerSourceID
        var editingServerSourceID = HarnessSettingsStore.selectedServerSourceID
        var serverSourceNameString = HarnessSettingsStore.activeServerSource?.name ?? ""
        var serverURLString = HarnessSettingsStore.serverURL ?? ""
        var committedServerURLString = HarnessSettingsStore.isLocalDemoMode
            ? HarnessLocalDemo.baseURL
            : HarnessSettingsStore.serverURL ?? ""
        var isDemoMode = HarnessSettingsStore.isLocalDemoMode
        var demoServerURLString = HarnessSettingsStore.demoServerURL
        var tailscaleHostString = HarnessSettingsStore.tailscaleHost
        var harnessWebTokenString = HarnessSettingsStore.harnessWebToken
        var isDiscoveringServer = false
        var discoveredServers: [DiscoveredHarnessServer] = []
        var serverSetupMessage: String?
        var serverSetupError: String?
        var status: HarnessStatus?
        var workspaces: [Workspace] = []
        var logEntries: [LogEntry] = []
        var notifications: [CmuxNotification] = []
        var feedItems: [FeedItem] = []
        var pendingFeedReplyIDs: Set<String> = []
        var openCodeIntegration: OpenCodeIntegrationResponse?
        var isInstallingOpenCodeIntegration = false
        var isRefreshing = false
        var lastUpdated: Date?
        var errorMessage: String?
        var sessionSearchText = ""
        var sessionFilter: SessionFilter = .all

        var selectedWorkspaceID: String? = HarnessSettingsStore.lastSelectedWorkspaceID
        var detailTab: DetailTab = .terminal
        var isEasyModeEnabled = false
        var fullScreenText: String?
        var draftMessages: [String: String] = [:]
        var detailDrafts: [String: String] = HarnessSettingsStore.detailDrafts
        var detailDraft = HarnessSettingsStore.detailDraft(for: HarnessSettingsStore.lastSelectedWorkspaceID)
        var detailInputFocusRequest = 0
        var pendingPushApproval: PushApprovalNotification?

        var isShowingSettings = false
        var isShowingNewSession = false
        var isCreatingSession = false
        var quickSessionCreation: QuickSessionCreation?
        var pendingCreatedWorkspaceSelection: PendingCreatedWorkspaceSelection?
        var newSessionMode: NewSessionMode = .claude
        var newSessionProjectPath = "~/Documents/Development/sample-app"
        var newSessionBranchName = ""
        var newSessionJiraURL = ""
        var newSessionPrompt = ""
        var newSessionName = "Shell"
        var newSessionError: String?

        var renameWorkspaceID: String?
        var renameText = ""

        var gitStatus: GitStatus?
        var gitError: String?
        var isLoadingGit = false
        var gitSegment: GitDetailSegment = .status
        var diffSheet: DiffSheet?
        var prCommentsResponse: GitHubPRCommentsResponse?
        var prCommentsError: String?
        var isLoadingPRComments = false
        var includeResolvedPRComments = false
        var projectSkills: [ProjectSkill] = []
        var userSkills: [ProjectSkill] = []
        var skillsError: String?
        var isLoadingSkills = false
        var isShowingFileSearch = false
        var fileSearchQuery = ""
        var fileSearchResults: [ProjectFileMatch] = []
        var fileSearchError: String?
        var isSearchingFiles = false
        var isShowingJiraTickets = false
        var jiraTickets: [JiraTicket] = []
        var jiraTicketsError: String?
        var isLoadingJiraTickets = false
        var jiraLookupQuery = ""
        var resolvedJiraTicket: JiraTicket?
        var jiraLookupError: String?
        var isResolvingJiraTicket = false
        var terminalAttachments: [String: [TerminalAttachment]] = [:]

        var hasSkills: Bool {
            !projectSkills.isEmpty || !userSkills.isEmpty
        }

        var sortedWorkspaces: [Workspace] {
            workspaces.sorted {
                if $0.starred != $1.starred {
                    return $0.starred && !$1.starred
                }
                let displayOrder = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                if displayOrder != .orderedSame {
                    return displayOrder == .orderedAscending
                }
                let uuidOrder = $0.uuid.localizedCaseInsensitiveCompare($1.uuid)
                if uuidOrder != .orderedSame {
                    return uuidOrder == .orderedAscending
                }
                return $0.index < $1.index
            }
        }

        var visibleWorkspaces: [Workspace] {
            let searchText = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
            return sortedWorkspaces.filter { workspace in
                sessionFilterIncludes(workspace)
                && (searchText.isEmpty || workspace.matchesSearch(searchText))
            }
        }

        var workspaceSessionGroups: [WorkspaceSessionGroup] {
            WorkspaceSessionGroup.groups(from: workspaces)
        }

        var visibleWorkspaceGroups: [WorkspaceSessionGroup] {
            let searchText = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
            return workspaceSessionGroups.filter { group in
                sessionFilterIncludes(group)
                && (searchText.isEmpty || group.matchesSearch(searchText))
            }
        }

        var selectedWorkspace: Workspace? {
            guard let selectedWorkspaceID else { return nil }
            return workspaces.first { $0.id == selectedWorkspaceID }
        }

        var selectedWorkspaceGroup: WorkspaceSessionGroup? {
            guard let selectedWorkspaceID else { return nil }
            return workspaceSessionGroups.first { $0.containsWorkspace(id: selectedWorkspaceID) }
        }

        func unreadCount(forWorkspaceID workspaceID: String?) -> Int {
            guard let workspaceID else { return 0 }
            return notifications.count { $0.isUnread && $0.workspaceId == workspaceID }
        }

        func unreadCount(forSurfaceID surfaceID: String?) -> Int {
            guard let surfaceID else { return 0 }
            return notifications.count { $0.isUnread && $0.surfaceId == surfaceID }
        }

        func unreadCount(for group: WorkspaceSessionGroup) -> Int {
            let workspaceUUIDs = Set(group.workspaces.map(\.uuid))
            return notifications.count { $0.isUnread && $0.workspaceId.map { workspaceUUIDs.contains($0) } == true }
        }

        var waitingCount: Int {
            workspaceSessionGroups.filter { sessionState(for: $0) == .waiting }.count
        }

        var sessionCount: Int {
            workspaceSessionGroups.count
        }

        var isConnected: Bool {
            status?.connected == true
        }

        var hasSocket: Bool {
            status?.socketFound == true
        }

        var isServerConfigured: Bool {
            isDemoMode || !committedServerURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        var activeServerSource: HarnessServerSource? {
            guard let selectedServerSourceID else { return serverSources.first }
            return serverSources.first { $0.id == selectedServerSourceID } ?? serverSources.first
        }

        var activeServerSourceName: String {
            if isDemoMode {
                return "Local Demo"
            }
            return activeServerSource?.name ?? "CMUX Server"
        }

        var activeServerSourceURLString: String {
            activeServerSource?.urlString ?? committedServerURLString
        }

        var isEditingSavedServerSource: Bool {
            guard let editingServerSourceID else { return false }
            return serverSources.contains { $0.id == editingServerSourceID }
        }

        func sessionState(for workspace: Workspace) -> WorkspaceSessionState {
            return workspaceSessionState(for: workspace, entries: logEntries)
        }

        func latestLog(for workspace: Workspace) -> LogEntry? {
            latestRelevantLog(for: workspace, entries: logEntries)
        }

        func sessionState(for group: WorkspaceSessionGroup) -> WorkspaceSessionState {
            workspaceSessionState(for: group, entries: logEntries)
        }

        private func sessionFilterIncludes(_ workspace: Workspace) -> Bool {
            switch sessionFilter {
            case .all:
                return true
            case .needsYou:
                return sessionState(for: workspace) == .waiting
            case .auto:
                return workspace.resolvedAutoMode.isEnabled
            }
        }

        private func sessionFilterIncludes(_ group: WorkspaceSessionGroup) -> Bool {
            switch sessionFilter {
            case .all:
                return true
            case .needsYou:
                return sessionState(for: group) == .waiting
            case .auto:
                return group.workspaces.contains { $0.resolvedAutoMode.isEnabled }
            }
        }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case onAppear
        case onDisappear
        case refresh
        case refreshSucceeded(RefreshPayload)
        case refreshFailed(String)
        case newServerSourceTapped
        case editServerSource(String)
        case selectServerSource(String)
        case deleteServerSource(String)
        case saveServerTapped
        case startLocalDemoTapped
        case exitDemoModeTapped
        case useDemoServerTapped
        case discoverServer
        case serverDiscoverySucceeded([DiscoveredHarnessServer])
        case serverDiscoveryFailed(String)
        case useDiscoveredServer(DiscoveredHarnessServer)
        case probeTailscaleHostTapped
        case tailscaleProbeSucceeded(String)
        case tailscaleProbeFailed(String)
        case clearError
        case replyToFeed(requestID: String, kind: String, action: String?, mode: String?, selections: [String]?)
        case feedReplySucceeded(String)
        case feedReplyFailed(requestID: String, message: String)
        case installOpenCodeIntegration
        case installOpenCodeIntegrationSucceeded(OpenCodeIntegrationResponse)
        case installOpenCodeIntegrationFailed(String)
        case markNotificationsRead(workspaceID: String?, surfaceID: String?)
        case notificationsMarkedRead(workspaceID: String?, surfaceID: String?)
        case notificationsMarkFailed(String)

        case settingsButtonTapped
        case dismissSettings
        case newSessionButtonTapped
        case newSessionFromWorkspaceTapped(workspaceID: String)
        case dismissNewSession
        case newSessionJiraChanged(String)
        case createNewSession
        case createNewSessionSucceeded(NewSessionResponse)
        case createNewSessionFailed(String)

        case selectWorkspace(String?)
        case selectWorkspacePane(String)
        case openPushApproval(PushApprovalNotification)
        case detailTabChanged(DetailTab)
        case setEasyMode(Bool)
        case screenTick
        case screenSucceeded(workspaceID: String, response: ScreenResponse)
        case screenFailed(String)
        case draftChanged(workspaceID: String, text: String)
        case sendDraft(workspaceID: String)
        case sendDetailDraft
        case detailInputFocusHandled(Int)
        case sendKey(workspaceID: String, HarnessKey)
        case sendKeys(workspaceID: String, [HarnessKey])
        case requestFinished
        case requestFailed(String)

        case toggleGlobal(Bool)
        case toggleWorkspace(workspaceID: String, enabled: Bool)
        case setWorkspaceAutoMode(workspaceID: String, mode: WorkspaceAutoMode)
        case toggleWorkspaceStarred(workspaceID: String, starred: Bool)
        case renameRequested(workspaceID: String)
        case commitRename
        case cancelRename

        case gitTick
        case gitSucceeded(workspaceID: String, GitStatus)
        case gitFailed(String)
        case gitSegmentChanged(GitDetailSegment)
        case stageFile(String)
        case unstageFile(String)
        case requestDiff(file: String, section: GitFileSection)
        case diffSucceeded(file: String, section: GitFileSection, diff: String)
        case diffFailed(file: String, section: GitFileSection, message: String)
        case closeDiff
        case appendDiffLineReviewComment(DiffLineReviewComment)
        case setPRCommentsIncludeResolved(Bool)
        case loadPRComments
        case prCommentsSucceeded(workspaceID: String, GitHubPRCommentsResponse)
        case prCommentsFailed(String)
        case appendPRCommentThread(GitHubPRThread)
        case requestFixForPRCommentThread(GitHubPRThread)
        case loadSkills
        case skillsSucceeded(workspaceID: String, SkillsResponse)
        case skillsFailed(String)
        case appendSkillInvocation(ProjectSkill)
        case appendCodexSkillInvocation(ProjectSkill)
        case appendSkillFilePath(ProjectSkill)
        case fileSearchTapped
        case dismissFileSearch
        case fileSearchQueryChanged(String)
        case fileSearchSucceeded(workspaceID: String, query: String, FileSearchResponse)
        case fileSearchFailed(query: String, message: String)
        case appendFilePath(ProjectFileMatch)
        case jiraTicketsTapped
        case dismissJiraTickets
        case loadAssignedJiraTickets
        case assignedJiraTicketsSucceeded(JiraTicketsResponse)
        case assignedJiraTicketsFailed(String)
        case jiraLookupQueryChanged(String)
        case resolveJiraTicket
        case jiraTicketResolved(JiraTicketResponse)
        case jiraTicketResolveFailed(String)
        case appendJiraTicketReference(JiraTicket)
        case attachmentFilesPicked(workspaceID: String, [URL])
        case attachmentUploadSucceeded(workspaceID: String, attachmentID: UUID, AttachmentUploadResponse)
        case attachmentUploadFailed(workspaceID: String, attachmentID: UUID, String)
        case removeAttachment(workspaceID: String, attachmentID: UUID)
        case retryAttachment(workspaceID: String, attachmentID: UUID)
        case attachmentPickerFailed(String)
    }

    var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .binding(_),
                 .onAppear,
                 .onDisappear,
                 .refresh,
                 .refreshSucceeded(_),
                 .refreshFailed(_),
                 .newServerSourceTapped,
                 .editServerSource(_),
                 .selectServerSource(_),
                 .deleteServerSource(_),
                 .saveServerTapped,
                 .startLocalDemoTapped,
                 .exitDemoModeTapped,
                 .useDemoServerTapped,
                 .discoverServer,
                 .serverDiscoverySucceeded(_),
                 .serverDiscoveryFailed(_),
                 .useDiscoveredServer(_),
                 .probeTailscaleHostTapped,
                 .tailscaleProbeSucceeded(_),
                 .tailscaleProbeFailed(_),
                 .clearError,
                 .replyToFeed(requestID: _, kind: _, action: _, mode: _, selections: _),
                 .feedReplySucceeded(_),
                 .feedReplyFailed(requestID: _, message: _),
                 .installOpenCodeIntegration,
                 .installOpenCodeIntegrationSucceeded(_),
                 .installOpenCodeIntegrationFailed(_),
                 .markNotificationsRead(workspaceID: _, surfaceID: _),
                 .notificationsMarkedRead(workspaceID: _, surfaceID: _),
                 .notificationsMarkFailed(_):
                return reduceConnection(into: &state, action: action)

            case .settingsButtonTapped,
                 .dismissSettings,
                 .newSessionButtonTapped,
                 .newSessionFromWorkspaceTapped(workspaceID: _),
                 .dismissNewSession,
                 .newSessionJiraChanged(_),
                 .createNewSession,
                 .createNewSessionSucceeded(_),
                 .createNewSessionFailed(_):
                return reduceNewSession(into: &state, action: action)

            case .selectWorkspace(_),
                 .selectWorkspacePane(_),
                 .openPushApproval(_),
                 .detailTabChanged(_),
                 .setEasyMode(_),
                 .screenTick,
                 .screenSucceeded(workspaceID: _, response: _),
                 .screenFailed(_),
                 .draftChanged(workspaceID: _, text: _),
                 .sendDraft(workspaceID: _),
                 .sendDetailDraft,
                 .detailInputFocusHandled(_),
                 .sendKey(workspaceID: _, _),
                 .sendKeys(workspaceID: _, _),
                 .requestFinished,
                 .requestFailed(_),
                 .toggleGlobal(_),
                 .toggleWorkspace(workspaceID: _, enabled: _),
                 .setWorkspaceAutoMode(workspaceID: _, mode: _),
                 .toggleWorkspaceStarred(workspaceID: _, starred: _),
                 .renameRequested(workspaceID: _),
                 .commitRename,
                 .cancelRename:
                return reduceSession(into: &state, action: action)

            case .gitTick,
                 .gitSucceeded(workspaceID: _, _),
                 .gitFailed(_),
                 .gitSegmentChanged(_),
                 .stageFile(_),
                 .unstageFile(_),
                 .requestDiff(file: _, section: _),
                 .diffSucceeded(file: _, section: _, diff: _),
                 .diffFailed(file: _, section: _, message: _),
                 .closeDiff,
                 .appendDiffLineReviewComment(_),
                 .setPRCommentsIncludeResolved(_),
                 .loadPRComments,
                 .prCommentsSucceeded(workspaceID: _, _),
                 .prCommentsFailed(_),
                 .appendPRCommentThread(_),
                 .requestFixForPRCommentThread(_):
                return reduceGit(into: &state, action: action)

            case .loadSkills,
                 .skillsSucceeded(workspaceID: _, _),
                 .skillsFailed(_),
                 .appendSkillInvocation(_),
                 .appendCodexSkillInvocation(_),
                 .appendSkillFilePath(_),
                 .fileSearchTapped,
                 .dismissFileSearch,
                 .fileSearchQueryChanged(_),
                 .fileSearchSucceeded(workspaceID: _, query: _, _),
                 .fileSearchFailed(query: _, message: _),
                 .appendFilePath(_),
                 .jiraTicketsTapped,
                 .dismissJiraTickets,
                 .loadAssignedJiraTickets,
                 .assignedJiraTicketsSucceeded(_),
                 .assignedJiraTicketsFailed(_),
                 .jiraLookupQueryChanged(_),
                 .resolveJiraTicket,
                 .jiraTicketResolved(_),
                 .jiraTicketResolveFailed(_),
                 .appendJiraTicketReference(_):
                return reduceTools(into: &state, action: action)

            case .attachmentFilesPicked(workspaceID: _, _),
                 .attachmentUploadSucceeded(workspaceID: _, attachmentID: _, _),
                 .attachmentUploadFailed(workspaceID: _, attachmentID: _, _),
                 .removeAttachment(workspaceID: _, attachmentID: _),
                 .retryAttachment(workspaceID: _, attachmentID: _),
                 .attachmentPickerFailed(_):
                return reduceAttachments(into: &state, action: action)
            }
        }
    }
}
