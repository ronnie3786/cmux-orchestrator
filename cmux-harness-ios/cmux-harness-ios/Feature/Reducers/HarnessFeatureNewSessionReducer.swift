import ComposableArchitecture
import Foundation

extension HarnessFeature {
    func reduceNewSession(into state: inout State, action: Action) -> Effect<Action> {
        switch action {
            case .settingsButtonTapped:
                state.serverSources = HarnessSettingsStore.serverSources
                state.selectedServerSourceID = HarnessSettingsStore.selectedServerSourceID
                state.editingServerSourceID = state.selectedServerSourceID
                state.serverSourceNameString = state.activeServerSource?.name ?? ""
                state.serverURLString = state.activeServerSourceURLString
                state.isShowingSettings = true
                return .none

            case .dismissSettings:
                state.isShowingSettings = false
                state.editingServerSourceID = state.selectedServerSourceID
                state.serverSourceNameString = state.activeServerSource?.name ?? ""
                state.serverURLString = state.activeServerSourceURLString
                return .none

            case .newSessionButtonTapped:
                state.newSessionMode = .claude
                state.newSessionBranchName = ""
                state.newSessionJiraURL = ""
                state.newSessionPrompt = ""
                state.newSessionName = "Shell"
                state.newSessionError = nil
                state.quickSessionCreation = nil
                state.pendingCreatedWorkspaceSelection = nil
                state.isShowingNewSession = true
                return .none

            case let .newSessionFromWorkspaceTapped(workspaceID):
                guard !state.isCreatingSession, state.quickSessionCreation == nil else {
                    return .none
                }
                guard let workspace = state.workspaces.first(where: { $0.id == workspaceID }) else {
                    return .none
                }
                guard let projectPath = workspaceDirectory(for: workspace) else {
                    state.errorMessage = "Couldn't find a directory for this session yet."
                    return .none
                }
                let sessionName = shellSessionName(for: workspace)
                state.isCreatingSession = true
                state.quickSessionCreation = QuickSessionCreation(
                    workspaceID: workspaceID,
                    directoryPath: projectPath,
                    phase: .creating
                )
                state.pendingCreatedWorkspaceSelection = nil
                state.newSessionError = nil
                state.errorMessage = nil
                return createSessionEffect(
                    state: state,
                    projectPath: projectPath,
                    branchName: "",
                    jiraURL: "",
                    prompt: "",
                    mode: .shell,
                    sessionName: sessionName
                )

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
                return createSessionEffect(
                    state: state,
                    projectPath: projectPath,
                    branchName: state.newSessionBranchName.trimmingCharacters(in: .whitespacesAndNewlines),
                    jiraURL: state.newSessionJiraURL.trimmingCharacters(in: .whitespacesAndNewlines),
                    prompt: state.newSessionPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                    mode: state.newSessionMode,
                    sessionName: sessionName.isEmpty ? "Shell" : sessionName
                )

            case let .createNewSessionSucceeded(response):
                let shouldSelectCreatedSession = state.quickSessionCreation != nil
                state.isCreatingSession = false
                state.isShowingNewSession = false
                if shouldSelectCreatedSession {
                    state.quickSessionCreation?.phase = .switching
                    state.pendingCreatedWorkspaceSelection = pendingCreatedWorkspaceSelection(from: response)
                }
                return .run { [clock = self.clock] send in
                    try? await clock.sleep(for: .milliseconds(750))
                    await send(.refresh)
                }

            case let .createNewSessionFailed(message):
                let wasQuickCreate = state.quickSessionCreation != nil
                state.isCreatingSession = false
                state.quickSessionCreation = nil
                state.pendingCreatedWorkspaceSelection = nil
                if wasQuickCreate {
                    state.errorMessage = "Couldn't start a new session: \(message)"
                } else {
                    state.newSessionError = message
                }
                return .none

        default:
            return .none
        }
    }
}
