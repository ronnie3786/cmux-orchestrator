import ComposableArchitecture
import Foundation

@Reducer
struct HarnessFeature {
    @Dependency(\.continuousClock) var clock
    @Dependency(\.date.now) var now
    @Dependency(\.harnessClient) var harnessClient
    @Dependency(\.uuid) var uuid

    @ObservableState
    struct State: Equatable {
        var serverURLString = HarnessSettingsStore.serverURL
        var committedServerURLString = HarnessSettingsStore.serverURL
        var status: HarnessStatus?
        var workspaces: [Workspace] = []
        var logEntries: [LogEntry] = []
        var isRefreshing = false
        var lastUpdated: Date?
        var errorMessage: String?
        var sessionSearchText = ""
        var sessionFilter: SessionFilter = .all

        var selectedWorkspaceID: String?
        var detailTab: DetailTab = .terminal
        var isDetailInfoExpanded = false
        var fullScreenText: String?
        var draftMessages: [String: String] = [:]
        var detailDraft = ""
        var detailInputFocusRequest = 0

        var isShowingSettings = false
        var isShowingNewSession = false
        var isCreatingSession = false
        var newSessionMode: NewSessionMode = .claude
        var newSessionProjectPath = "~/Documents/Development/Doximity-Claude"
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
        var diffSheet: DiffSheet?
        var projectSkills: [ProjectSkill] = []
        var userSkills: [ProjectSkill] = []
        var skillsError: String?
        var isLoadingSkills = false
        var isShowingFileSearch = false
        var fileSearchQuery = ""
        var fileSearchResults: [ProjectFileMatch] = []
        var fileSearchError: String?
        var isSearchingFiles = false

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
                sessionFilter.includes(workspace, entries: logEntries)
                && (searchText.isEmpty || workspace.matchesSearch(searchText))
            }
        }

        var selectedWorkspace: Workspace? {
            guard let selectedWorkspaceID else { return nil }
            return workspaces.first { $0.id == selectedWorkspaceID }
        }

        var waitingCount: Int {
            workspaces.filter { sessionState(for: $0) == .waiting }.count
        }

        var sessionCount: Int {
            workspaces.count
        }

        var isConnected: Bool {
            status?.connected == true
        }

        var hasSocket: Bool {
            status?.socketFound == true
        }

        func sessionState(for workspace: Workspace) -> WorkspaceSessionState {
            workspaceSessionState(for: workspace, entries: logEntries)
        }

        func latestLog(for workspace: Workspace) -> LogEntry? {
            latestRelevantLog(for: workspace, entries: logEntries)
        }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case onAppear
        case onDisappear
        case refresh
        case refreshSucceeded(RefreshPayload)
        case refreshFailed(String)
        case saveServerTapped
        case clearError

        case settingsButtonTapped
        case dismissSettings
        case newSessionButtonTapped
        case dismissNewSession
        case newSessionJiraChanged(String)
        case createNewSession
        case createNewSessionSucceeded(NewSessionResponse)
        case createNewSessionFailed(String)

        case selectWorkspace(String?)
        case detailTabChanged(DetailTab)
        case toggleDetailInfo
        case screenTick
        case screenSucceeded(workspaceID: String, response: ScreenResponse)
        case screenFailed(String)
        case draftChanged(workspaceID: String, text: String)
        case sendDraft(workspaceID: String)
        case sendDetailDraft
        case detailInputFocusHandled(Int)
        case sendKey(workspaceID: String, HarnessKey)
        case requestFinished
        case requestFailed(String)

        case toggleGlobal(Bool)
        case toggleWorkspace(workspaceID: String, enabled: Bool)
        case toggleWorkspaceStarred(workspaceID: String, starred: Bool)
        case renameRequested(workspaceID: String)
        case commitRename
        case cancelRename

        case gitTick
        case gitSucceeded(workspaceID: String, GitStatus)
        case gitFailed(String)
        case stageFile(String)
        case unstageFile(String)
        case requestDiff(file: String, section: GitFileSection)
        case diffSucceeded(file: String, section: GitFileSection, diff: String)
        case diffFailed(file: String, section: GitFileSection, message: String)
        case closeDiff
        case loadSkills
        case skillsSucceeded(workspaceID: String, SkillsResponse)
        case skillsFailed(String)
        case appendSkillInvocation(ProjectSkill)
        case appendSkillFilePath(ProjectSkill)
        case fileSearchTapped
        case dismissFileSearch
        case fileSearchQueryChanged(String)
        case fileSearchSucceeded(workspaceID: String, query: String, FileSearchResponse)
        case fileSearchFailed(query: String, message: String)
        case appendFilePath(ProjectFileMatch)
    }

    var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .onAppear:
                return .merge(
                    .send(.refresh),
                    .run { [clock = self.clock] send in
                        while !Task.isCancelled {
                            try? await clock.sleep(for: .seconds(2))
                            guard !Task.isCancelled else { return }
                            await send(.refresh)
                        }
                    }
                    .cancellable(id: pollingCancelID, cancelInFlight: true)
                )

            case .onDisappear:
                return .merge(
                    .cancel(id: pollingCancelID),
                    .cancel(id: screenPollingCancelID),
                    .cancel(id: gitPollingCancelID),
                    .cancel(id: fileSearchCancelID)
                )

            case .refresh:
                state.isRefreshing = state.workspaces.isEmpty
                return .run { [client = self.harnessClient, baseURLString = state.committedServerURLString] send in
                    do {
                        async let status = client.status(baseURLString)
                        async let log = client.log(baseURLString)
                        let payload = try await RefreshPayload(status: status, log: log)
                        await send(.refreshSucceeded(payload))
                    } catch {
                        await send(.refreshFailed(HarnessAPI.message(for: error)))
                    }
                }

            case let .refreshSucceeded(payload):
                state.isRefreshing = false
                state.errorMessage = nil
                state.status = payload.status
                state.workspaces = payload.status.workspaces
                state.logEntries = payload.log
                state.lastUpdated = self.now
                trimDrafts(&state)
                if let selected = state.selectedWorkspaceID,
                   !state.workspaces.contains(where: { $0.id == selected }) {
                    state.selectedWorkspaceID = nil
                    state.isDetailInfoExpanded = false
                    state.fullScreenText = nil
                    state.gitStatus = nil
                    state.detailDraft = ""
                    state.projectSkills = []
                    state.userSkills = []
                    state.skillsError = nil
                    state.isLoadingSkills = false
                    state.isShowingFileSearch = false
                    state.fileSearchQuery = ""
                    state.fileSearchResults = []
                    state.fileSearchError = nil
                    state.isSearchingFiles = false
                    return .merge(
                        .cancel(id: screenPollingCancelID),
                        .cancel(id: gitPollingCancelID),
                        .cancel(id: fileSearchCancelID)
                    )
                }
                return .none

            case let .refreshFailed(message):
                state.isRefreshing = false
                state.errorMessage = message
                return .none

            case .saveServerTapped:
                let normalized = HarnessAPI.normalizedBaseURL(state.serverURLString)
                state.serverURLString = normalized
                state.committedServerURLString = normalized
                HarnessSettingsStore.serverURL = normalized
                state.isShowingSettings = false
                state.errorMessage = nil
                return .send(.refresh)

            case .clearError:
                state.errorMessage = nil
                return .none

            case .settingsButtonTapped:
                state.serverURLString = state.committedServerURLString
                state.isShowingSettings = true
                return .none

            case .dismissSettings:
                state.isShowingSettings = false
                state.serverURLString = state.committedServerURLString
                return .none

            case .newSessionButtonTapped:
                state.newSessionMode = .claude
                state.newSessionBranchName = ""
                state.newSessionJiraURL = ""
                state.newSessionPrompt = ""
                state.newSessionName = "Shell"
                state.newSessionError = nil
                state.isShowingNewSession = true
                return .none

            case .dismissNewSession:
                state.isShowingNewSession = false
                state.isCreatingSession = false
                return .none

            case let .newSessionJiraChanged(value):
                state.newSessionJiraURL = value
                if let key = jiraKey(from: value), state.newSessionBranchName.isEmpty {
                    state.newSessionBranchName = key
                }
                return .none

            case .createNewSession:
                let projectPath = state.newSessionProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !projectPath.isEmpty else {
                    state.newSessionError = "Project path is required"
                    return .none
                }

                let sessionName = state.newSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
                state.isCreatingSession = true
                state.newSessionError = nil
                return .run {
                    [
                        client = self.harnessClient,
                        baseURLString = state.committedServerURLString,
                        projectPath,
                        branchName = state.newSessionBranchName.trimmingCharacters(in: .whitespacesAndNewlines),
                        jiraURL = state.newSessionJiraURL.trimmingCharacters(in: .whitespacesAndNewlines),
                        prompt = state.newSessionPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                        mode = state.newSessionMode,
                        sessionName
                    ] send in
                    do {
                        let response = try await client.createSession(
                            baseURLString,
                            projectPath,
                            branchName,
                            jiraURL,
                            prompt,
                            mode,
                            sessionName.isEmpty ? "Shell" : sessionName
                        )
                        await send(.createNewSessionSucceeded(response))
                    } catch {
                        await send(.createNewSessionFailed(HarnessAPI.message(for: error)))
                    }
                }

            case .createNewSessionSucceeded:
                state.isCreatingSession = false
                state.isShowingNewSession = false
                return .run { [clock = self.clock] send in
                    try? await clock.sleep(for: .milliseconds(750))
                    await send(.refresh)
                }

            case let .createNewSessionFailed(message):
                state.isCreatingSession = false
                state.newSessionError = message
                return .none

            case let .selectWorkspace(id):
                state.selectedWorkspaceID = id
                state.detailTab = .terminal
                state.isDetailInfoExpanded = false
                state.fullScreenText = nil
                state.gitStatus = nil
                state.gitError = nil
                state.diffSheet = nil
                state.detailDraft = ""
                state.projectSkills = []
                state.userSkills = []
                state.skillsError = nil
                state.isLoadingSkills = false
                state.isShowingFileSearch = false
                state.fileSearchQuery = ""
                state.fileSearchResults = []
                state.fileSearchError = nil
                state.isSearchingFiles = false
                guard id != nil else {
                    return .merge(
                        .cancel(id: screenPollingCancelID),
                        .cancel(id: gitPollingCancelID),
                        .cancel(id: fileSearchCancelID)
                    )
                }
                return .merge(
                    .send(.screenTick),
                    screenPollingEffect(),
                    .cancel(id: gitPollingCancelID)
                )

            case let .detailTabChanged(tab):
                state.detailTab = tab
                if tab == .git {
                    return .merge(.send(.gitTick), gitPollingEffect())
                }
                if tab == .skills {
                    return .merge(
                        .send(.loadSkills),
                        .cancel(id: gitPollingCancelID)
                    )
                }
                return .cancel(id: gitPollingCancelID)

            case .toggleDetailInfo:
                state.isDetailInfoExpanded.toggle()
                return .none

            case .screenTick:
                guard let workspace = state.selectedWorkspace else { return .none }
                return .run { [client = self.harnessClient, baseURLString = state.committedServerURLString, workspace] send in
                    do {
                        let response = try await client.screen(baseURLString, workspace.index, 200)
                        await send(.screenSucceeded(workspaceID: workspace.id, response: response))
                    } catch {
                        await send(.screenFailed(HarnessAPI.message(for: error)))
                    }
                }

            case let .screenSucceeded(workspaceID, response):
                guard state.selectedWorkspaceID == workspaceID else { return .none }
                state.fullScreenText = response.screen
                return .none

            case let .screenFailed(message):
                state.errorMessage = message
                return .none

            case let .draftChanged(workspaceID, text):
                state.draftMessages[workspaceID] = text
                return .none

            case let .sendDraft(workspaceID):
                guard let workspace = state.workspaces.first(where: { $0.id == workspaceID }) else { return .none }
                let message = (state.draftMessages[workspaceID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !message.isEmpty else { return .none }
                state.draftMessages[workspaceID] = ""
                return sendTextEffect(state: state, workspace: workspace, message: message)

            case .sendDetailDraft:
                guard let workspace = state.selectedWorkspace else { return .none }
                let message = state.detailDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !message.isEmpty else { return .none }
                state.detailDraft = ""
                return sendTextEffect(state: state, workspace: workspace, message: message)

            case let .detailInputFocusHandled(request):
                guard state.detailInputFocusRequest == request else { return .none }
                state.detailInputFocusRequest = 0
                return .none

            case let .sendKey(workspaceID, key):
                guard let workspace = state.workspaces.first(where: { $0.id == workspaceID }) else { return .none }
                return .run { [client = self.harnessClient, baseURLString = state.committedServerURLString, workspace, key] send in
                    do {
                        _ = try await client.sendKey(baseURLString, workspace.index, key, workspace.surfaceId)
                        await send(.requestFinished)
                        await send(.screenTick)
                    } catch {
                        await send(.requestFailed(HarnessAPI.message(for: error)))
                    }
                }

            case .requestFinished:
                state.errorMessage = nil
                return .none

            case let .requestFailed(message):
                state.errorMessage = message
                return .none

            case let .toggleGlobal(enabled):
                state.status?.enabled = enabled
                return .run { [client = self.harnessClient, baseURLString = state.committedServerURLString, enabled] send in
                    do {
                        _ = try await client.setGlobalEnabled(baseURLString, enabled)
                        await send(.requestFinished)
                    } catch {
                        await send(.requestFailed(HarnessAPI.message(for: error)))
                    }
                }

            case let .toggleWorkspace(workspaceID, enabled):
                guard let workspaceIndex = state.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
                    return .none
                }
                state.workspaces[workspaceIndex].enabled = enabled
                let workspace = state.workspaces[workspaceIndex]
                return .run { [client = self.harnessClient, baseURLString = state.committedServerURLString, workspace, enabled] send in
                    do {
                        _ = try await client.setWorkspaceEnabled(baseURLString, workspace.index, enabled)
                        await send(.requestFinished)
                    } catch {
                        await send(.requestFailed(HarnessAPI.message(for: error)))
                    }
                }

            case let .toggleWorkspaceStarred(workspaceID, starred):
                guard let workspaceIndex = state.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
                    return .none
                }
                state.workspaces[workspaceIndex].starred = starred
                let workspace = state.workspaces[workspaceIndex]
                return .run { [client = self.harnessClient, baseURLString = state.committedServerURLString, workspace, starred] send in
                    do {
                        _ = try await client.setWorkspaceStarred(baseURLString, workspace.index, starred)
                        await send(.requestFinished)
                    } catch {
                        await send(.requestFailed(HarnessAPI.message(for: error)))
                    }
                }

            case let .renameRequested(workspaceID):
                guard let workspace = state.workspaces.first(where: { $0.id == workspaceID }) else { return .none }
                state.renameWorkspaceID = workspaceID
                state.renameText = workspace.displayName
                return .none

            case .commitRename:
                guard let workspaceID = state.renameWorkspaceID,
                      let workspaceIndex = state.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
                    state.renameWorkspaceID = nil
                    state.renameText = ""
                    return .none
                }
                let newName = state.renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !newName.isEmpty else {
                    state.renameWorkspaceID = nil
                    state.renameText = ""
                    return .none
                }
                state.workspaces[workspaceIndex].customName = newName
                let workspace = state.workspaces[workspaceIndex]
                state.renameWorkspaceID = nil
                state.renameText = ""
                return .run { [client = self.harnessClient, baseURLString = state.committedServerURLString, workspace, newName] send in
                    do {
                        _ = try await client.renameWorkspace(baseURLString, workspace.index, newName)
                        await send(.requestFinished)
                        await send(.refresh)
                    } catch {
                        await send(.requestFailed(HarnessAPI.message(for: error)))
                    }
                }

            case .cancelRename:
                state.renameWorkspaceID = nil
                state.renameText = ""
                return .none

            case .gitTick:
                guard let workspace = state.selectedWorkspace else { return .none }
                state.isLoadingGit = state.gitStatus == nil
                return .run { [client = self.harnessClient, baseURLString = state.committedServerURLString, workspace] send in
                    do {
                        let status = try await client.gitStatus(baseURLString, workspace.index)
                        await send(.gitSucceeded(workspaceID: workspace.id, status))
                    } catch {
                        await send(.gitFailed(HarnessAPI.message(for: error)))
                    }
                }

            case let .gitSucceeded(workspaceID, status):
                guard state.selectedWorkspaceID == workspaceID else { return .none }
                state.isLoadingGit = false
                state.gitError = nil
                state.gitStatus = status
                return .none

            case let .gitFailed(message):
                state.isLoadingGit = false
                state.gitError = message
                return .none

            case let .stageFile(file):
                guard let workspace = state.selectedWorkspace else { return .none }
                return .run { [client = self.harnessClient, baseURLString = state.committedServerURLString, workspace, file] send in
                    do {
                        _ = try await client.stageFile(baseURLString, workspace.index, file)
                        await send(.gitTick)
                    } catch {
                        await send(.requestFailed(HarnessAPI.message(for: error)))
                    }
                }

            case let .unstageFile(file):
                guard let workspace = state.selectedWorkspace else { return .none }
                return .run { [client = self.harnessClient, baseURLString = state.committedServerURLString, workspace, file] send in
                    do {
                        _ = try await client.unstageFile(baseURLString, workspace.index, file)
                        await send(.gitTick)
                    } catch {
                        await send(.requestFailed(HarnessAPI.message(for: error)))
                    }
                }

            case let .requestDiff(file, section):
                guard let workspace = state.selectedWorkspace else { return .none }
                state.diffSheet = DiffSheet(id: self.uuid(), file: file, section: section, diff: "", isLoading: true)
                return .run { [client = self.harnessClient, baseURLString = state.committedServerURLString, workspace, file, section] send in
                    do {
                        let response = try await client.diff(baseURLString, workspace.index, file, section)
                        await send(.diffSucceeded(file: file, section: section, diff: response.diff ?? ""))
                    } catch {
                        await send(.diffFailed(file: file, section: section, message: HarnessAPI.message(for: error)))
                    }
                }

            case let .diffSucceeded(file, section, diff):
                guard state.diffSheet?.file == file, state.diffSheet?.section == section else { return .none }
                state.diffSheet?.diff = diff.isEmpty ? "(empty diff)" : diff
                state.diffSheet?.isLoading = false
                state.diffSheet?.error = nil
                return .none

            case let .diffFailed(file, section, message):
                guard state.diffSheet?.file == file, state.diffSheet?.section == section else { return .none }
                state.diffSheet?.isLoading = false
                state.diffSheet?.error = message
                return .none

            case .closeDiff:
                state.diffSheet = nil
                return .none

            case .loadSkills:
                guard let workspace = state.selectedWorkspace else { return .none }
                state.isLoadingSkills = !state.hasSkills
                state.skillsError = nil
                return .run { [client = self.harnessClient, baseURLString = state.committedServerURLString, workspace] send in
                    do {
                        let response = try await client.skills(baseURLString, workspace.index)
                        await send(.skillsSucceeded(workspaceID: workspace.id, response))
                    } catch {
                        await send(.skillsFailed(HarnessAPI.message(for: error)))
                    }
                }

            case let .skillsSucceeded(workspaceID, response):
                guard state.selectedWorkspaceID == workspaceID else { return .none }
                state.isLoadingSkills = false
                state.skillsError = nil
                state.projectSkills = response.resolvedProjectSkills
                state.userSkills = response.resolvedUserSkills
                return .none

            case let .skillsFailed(message):
                state.isLoadingSkills = false
                state.skillsError = message
                return .none

            case let .appendSkillInvocation(skill):
                state.detailDraft = appendPromptToken("/\(skill.name)", to: state.detailDraft)
                state.detailTab = .terminal
                state.detailInputFocusRequest += 1
                return .none

            case let .appendSkillFilePath(skill):
                state.detailDraft = appendPromptToken("`\(skill.skillFilePath)`", to: state.detailDraft)
                state.detailTab = .terminal
                state.detailInputFocusRequest += 1
                return .none

            case .fileSearchTapped:
                state.isShowingFileSearch = true
                state.fileSearchQuery = ""
                state.fileSearchResults = []
                state.fileSearchError = nil
                state.isSearchingFiles = false
                return .cancel(id: fileSearchCancelID)

            case .dismissFileSearch:
                state.isShowingFileSearch = false
                state.fileSearchQuery = ""
                state.fileSearchResults = []
                state.fileSearchError = nil
                state.isSearchingFiles = false
                return .cancel(id: fileSearchCancelID)

            case let .fileSearchQueryChanged(query):
                state.fileSearchQuery = query
                state.fileSearchError = nil
                let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmedQuery.count >= 3, let workspace = state.selectedWorkspace else {
                    state.fileSearchResults = []
                    state.isSearchingFiles = false
                    return .cancel(id: fileSearchCancelID)
                }
                state.isSearchingFiles = true
                return .run { [client = self.harnessClient, baseURLString = state.committedServerURLString, workspace, trimmedQuery] send in
                    do {
                        let response = try await client.searchFiles(baseURLString, workspace.index, trimmedQuery)
                        await send(.fileSearchSucceeded(workspaceID: workspace.id, query: trimmedQuery, response))
                    } catch {
                        await send(.fileSearchFailed(query: trimmedQuery, message: HarnessAPI.message(for: error)))
                    }
                }
                .cancellable(id: fileSearchCancelID, cancelInFlight: true)

            case let .fileSearchSucceeded(workspaceID, query, response):
                guard state.selectedWorkspaceID == workspaceID,
                      state.fileSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else {
                    return .none
                }
                state.isSearchingFiles = false
                state.fileSearchError = nil
                state.fileSearchResults = response.files
                return .none

            case let .fileSearchFailed(query, message):
                guard state.fileSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else {
                    return .none
                }
                state.isSearchingFiles = false
                state.fileSearchError = message
                return .none

            case let .appendFilePath(file):
                state.detailDraft = appendPromptToken("`\(file.path)`", to: state.detailDraft)
                state.detailTab = .terminal
                state.detailInputFocusRequest += 1
                state.isShowingFileSearch = false
                state.fileSearchQuery = ""
                state.fileSearchResults = []
                state.fileSearchError = nil
                state.isSearchingFiles = false
                return .cancel(id: fileSearchCancelID)
            }
        }
    }
}

extension HarnessFeature {
    private func screenPollingEffect() -> Effect<Action> {
        .run { [clock = self.clock] send in
            while !Task.isCancelled {
                try? await clock.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                await send(.screenTick)
            }
        }
        .cancellable(id: screenPollingCancelID, cancelInFlight: true)
    }

    private func gitPollingEffect() -> Effect<Action> {
        .run { [clock = self.clock] send in
            while !Task.isCancelled {
                try? await clock.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await send(.gitTick)
            }
        }
        .cancellable(id: gitPollingCancelID, cancelInFlight: true)
    }

    private func sendTextEffect(state: State, workspace: Workspace, message: String) -> Effect<Action> {
        .run { [client = self.harnessClient, baseURLString = state.committedServerURLString, workspace, message] send in
            do {
                _ = try await client.sendText(baseURLString, workspace.index, message + "\n", workspace.surfaceId)
                await send(.requestFinished)
                await send(.screenTick)
            } catch {
                await send(.requestFailed(HarnessAPI.message(for: error)))
            }
        }
    }
}

private let pollingCancelID = "cmux-harness-ios.polling"
private let screenPollingCancelID = "cmux-harness-ios.screen-polling"
private let gitPollingCancelID = "cmux-harness-ios.git-polling"
private let fileSearchCancelID = "cmux-harness-ios.file-search"

private func trimDrafts(_ state: inout HarnessFeature.State) {
    let activeIDs = Set(state.workspaces.map(\.id))
    state.draftMessages = state.draftMessages.filter { activeIDs.contains($0.key) }
}

private func jiraKey(from value: String) -> String? {
    let pattern = #"([A-Z]+-\d+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        return nil
    }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    guard let match = regex.firstMatch(in: value, range: range),
          let matchRange = Range(match.range(at: 1), in: value) else {
        return nil
    }
    return String(value[matchRange]).uppercased()
}

private func appendPromptToken(_ token: String, to draft: String) -> String {
    guard !draft.isEmpty else { return token }
    if draft.last?.isWhitespace == true {
        return draft + token
    }
    return draft + " " + token
}
