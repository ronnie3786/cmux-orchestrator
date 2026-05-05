import ComposableArchitecture
import Foundation

extension HarnessFeature {
    func reduceSession(into state: inout State, action: Action) -> Effect<Action> {
        switch action {
            case let .selectWorkspace(id):
                persistDetailDraft(&state)
                let workspaceToClear = id.flatMap { selectedID in
                    state.workspaces.first { $0.id == selectedID }
                }
                state.selectedWorkspaceID = id
                if state.isDemoMode {
                    HarnessSettingsStore.lastSelectedWorkspaceID = nil
                } else {
                    HarnessSettingsStore.lastSelectedWorkspaceID = id
                }
                state.detailTab = .terminal
                state.fullScreenText = nil
                state.gitStatus = nil
                state.gitError = nil
                state.gitSegment = .status
                state.diffSheet = nil
                state.prCommentsResponse = nil
                state.prCommentsError = nil
                state.isLoadingPRComments = false
                state.includeResolvedPRComments = false
                loadDetailDraft(for: id, into: &state)
                state.projectSkills = []
                state.userSkills = []
                state.skillsError = nil
                state.isLoadingSkills = false
                state.isShowingFileSearch = false
                state.fileSearchQuery = ""
                state.fileSearchResults = []
                state.fileSearchError = nil
                state.isSearchingFiles = false
                state.isShowingJiraTickets = false
                state.jiraTickets = []
                state.jiraTicketsError = nil
                state.isLoadingJiraTickets = false
                state.jiraLookupQuery = ""
                state.resolvedJiraTicket = nil
                state.jiraLookupError = nil
                state.isResolvingJiraTicket = false
                guard id != nil else {
                    return .merge(
                        .cancel(id: screenPollingCancelID),
                        .cancel(id: gitPollingCancelID),
                        .cancel(id: prCommentsCancelID),
                        .cancel(id: fileSearchCancelID),
                        .cancel(id: jiraTicketsCancelID),
                        .cancel(id: jiraLookupCancelID)
                    )
                }
                var effects: [Effect<Action>] = [
                    .send(.screenTick),
                    screenPollingEffect(),
                    .cancel(id: gitPollingCancelID),
                    .cancel(id: prCommentsCancelID)
                ]
                if let workspaceToClear {
                    effects.append(clearPushApprovalEffect(state: state, workspace: workspaceToClear))
                }
                return .merge(effects)

            case let .openPushApproval(notification):
                guard let workspaceID = matchingWorkspaceID(for: notification, in: state) else {
                    state.pendingPushApproval = notification
                    return .send(.refresh)
                }
                state.pendingPushApproval = nil
                state.sessionSearchText = ""
                state.sessionFilter = .all
                return .send(.selectWorkspace(workspaceID))

            case let .detailTabChanged(tab):
                state.detailTab = tab
                if tab == .git {
                    if state.gitSegment == .prComments {
                        return .merge(
                            .send(.loadPRComments),
                            .cancel(id: gitPollingCancelID)
                        )
                    }
                    return .merge(
                        .send(.gitTick),
                        gitPollingEffect(),
                        .cancel(id: prCommentsCancelID)
                    )
                }
                if tab == .skills {
                    return .merge(
                        .send(.loadSkills),
                        .cancel(id: gitPollingCancelID),
                        .cancel(id: prCommentsCancelID)
                    )
                }
                return .merge(
                    .cancel(id: gitPollingCancelID),
                    .cancel(id: prCommentsCancelID)
                )

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
                let attachments = state.terminalAttachments[workspace.id] ?? []
                guard !attachments.contains(where: { $0.status == .uploading }) else {
                    state.errorMessage = "Wait for attachment uploads to finish"
                    return .none
                }
                let paths = attachments.compactMap(\.uploadedPath)
                let message = state.detailDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !message.isEmpty || !paths.isEmpty else { return .none }
                let finalMessage = (paths + (message.isEmpty ? [] : [message])).joined(separator: " ")
                state.detailDraft = ""
                persistDetailDraft(&state)
                state.terminalAttachments[workspace.id] = []
                return sendTextEffect(state: state, workspace: workspace, message: finalMessage)

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
                let mode: WorkspaceAutoMode = enabled ? .auto : .off
                guard let workspaceIndex = state.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
                    return .none
                }
                state.workspaces[workspaceIndex].enabled = mode.isEnabled
                state.workspaces[workspaceIndex].autoMode = mode
                if !mode.isEnabled {
                    state.workspaces[workspaceIndex].autoEnabledAt = nil
                    state.workspaces[workspaceIndex].autoExpiresAt = nil
                }
                let workspace = state.workspaces[workspaceIndex]
                return .run { [client = self.harnessClient, baseURLString = state.committedServerURLString, workspace, mode] send in
                    do {
                        _ = try await client.setWorkspaceAutoMode(baseURLString, workspace.index, mode)
                        await send(.requestFinished)
                    } catch {
                        await send(.requestFailed(HarnessAPI.message(for: error)))
                    }
                }

            case let .setWorkspaceAutoMode(workspaceID, mode):
                guard let workspaceIndex = state.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
                    return .none
                }
                state.workspaces[workspaceIndex].enabled = mode.isEnabled
                state.workspaces[workspaceIndex].autoMode = mode
                if !mode.isEnabled {
                    state.workspaces[workspaceIndex].autoEnabledAt = nil
                    state.workspaces[workspaceIndex].autoExpiresAt = nil
                }
                let workspace = state.workspaces[workspaceIndex]
                return .run { [client = self.harnessClient, baseURLString = state.committedServerURLString, workspace, mode] send in
                    do {
                        _ = try await client.setWorkspaceAutoMode(baseURLString, workspace.index, mode)
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

        default:
            return .none
        }
    }
}
