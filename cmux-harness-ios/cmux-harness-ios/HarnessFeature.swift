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

        var selectedWorkspaceID: String?
        var detailTab: DetailTab = .terminal
        var fullScreenText: String?
        var draftMessages: [String: String] = [:]
        var detailDraft = ""

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

        var sortedWorkspaces: [Workspace] {
            workspaces.sorted {
                switch (lastActivityDate(for: $0), lastActivityDate(for: $1)) {
                case let (left?, right?) where left != right:
                    return left > right
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                default:
                    return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                }
            }
        }

        var selectedWorkspace: Workspace? {
            guard let selectedWorkspaceID else { return nil }
            return workspaces.first { $0.id == selectedWorkspaceID }
        }

        var activeCount: Int {
            workspaces.filter { sessionState(for: $0) == .active }.count
        }

        var waitingCount: Int {
            workspaces.filter { sessionState(for: $0) == .waiting }.count
        }

        var idleCount: Int {
            workspaces.filter { sessionState(for: $0) == .idle }.count
        }

        var isConnected: Bool {
            status?.connected == true
        }

        var hasSocket: Bool {
            status?.socketFound == true
        }

        func sessionState(for workspace: Workspace) -> WorkspaceSessionState {
            if let action = latestLog(for: workspace)?.action,
               action.localizedCaseInsensitiveContains("human") {
                return .waiting
            }
            return workspace.hasClaude ? .active : .idle
        }

        func latestLog(for workspace: Workspace) -> LogEntry? {
            logEntries.first { entry in
                entry.workspace == workspace.index
            }
        }

        func activity(for workspace: Workspace) -> [LogEntry] {
            logEntries.filter { $0.workspace == workspace.index }
        }

        func lastActivityDate(for workspace: Workspace) -> Date? {
            let logDates = activity(for: workspace).compactMap { harnessActivityDate(from: $0.timestamp) }
            let workspaceDates = [
                harnessActivityDate(from: workspace.lastCheck),
                harnessActivityDate(from: workspace.surfaceCreatedAt),
                workspace.sessionStart.map { Date(timeIntervalSince1970: $0) },
            ].compactMap(\.self)

            return (logDates + workspaceDates).max()
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
        case screenTick
        case screenSucceeded(workspaceID: String, response: ScreenResponse)
        case screenFailed(String)
        case draftChanged(workspaceID: String, text: String)
        case sendDraft(workspaceID: String)
        case sendDetailDraft
        case sendKey(workspaceID: String, HarnessKey)
        case requestFinished
        case requestFailed(String)

        case toggleGlobal(Bool)
        case toggleWorkspace(workspaceID: String, enabled: Bool)
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
                    .cancel(id: gitPollingCancelID)
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
                    state.fullScreenText = nil
                    state.gitStatus = nil
                    state.detailDraft = ""
                    return .merge(
                        .cancel(id: screenPollingCancelID),
                        .cancel(id: gitPollingCancelID)
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
                state.fullScreenText = nil
                state.gitStatus = nil
                state.gitError = nil
                state.diffSheet = nil
                state.detailDraft = ""
                guard id != nil else {
                    return .merge(
                        .cancel(id: screenPollingCancelID),
                        .cancel(id: gitPollingCancelID)
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
                return .cancel(id: gitPollingCancelID)

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

private func harnessActivityDate(from value: String?) -> Date? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let seconds = TimeInterval(trimmed) {
        return Date(timeIntervalSince1970: seconds)
    }

    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractionalFormatter.date(from: trimmed) {
        return date
    }

    return ISO8601DateFormatter().date(from: trimmed)
}

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
