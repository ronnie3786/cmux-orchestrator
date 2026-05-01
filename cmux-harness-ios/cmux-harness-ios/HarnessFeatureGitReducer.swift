import ComposableArchitecture
import Foundation

extension HarnessFeature {
    func reduceGit(into state: inout State, action: Action) -> Effect<Action> {
        switch action {
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

            case let .gitSegmentChanged(segment):
                state.gitSegment = segment
                switch segment {
                case .status:
                    return .merge(
                        .send(.gitTick),
                        gitPollingEffect(),
                        .cancel(id: prCommentsCancelID)
                    )
                case .prComments:
                    return .merge(
                        .send(.loadPRComments),
                        .cancel(id: gitPollingCancelID)
                    )
                }

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

            case let .appendDiffLineReviewComment(reviewComment):
                state.detailDraft = appendPromptBlock(
                    formatDiffLineReviewPrompt(reviewComment),
                    to: state.detailDraft
                )
                persistDetailDraft(&state)
                state.detailTab = .terminal
                state.diffSheet = nil
                state.detailInputFocusRequest += 1
                return .none

            case let .setPRCommentsIncludeResolved(includeResolved):
                guard state.includeResolvedPRComments != includeResolved else { return .none }
                state.includeResolvedPRComments = includeResolved
                state.prCommentsError = nil
                return .send(.loadPRComments)

            case .loadPRComments:
                guard let workspace = state.selectedWorkspace else { return .none }
                state.isLoadingPRComments = state.prCommentsResponse == nil
                state.prCommentsError = nil
                return .run {
                    [
                        client = self.harnessClient,
                        baseURLString = state.committedServerURLString,
                        workspace,
                        includeResolved = state.includeResolvedPRComments
                    ] send in
                    do {
                        let response = try await client.githubPRComments(
                            baseURLString,
                            workspace.index,
                            includeResolved
                        )
                        await send(.prCommentsSucceeded(workspaceID: workspace.id, response))
                    } catch {
                        await send(.prCommentsFailed(HarnessAPI.message(for: error)))
                    }
                }
                .cancellable(id: prCommentsCancelID, cancelInFlight: true)

            case let .prCommentsSucceeded(workspaceID, response):
                guard state.selectedWorkspaceID == workspaceID else { return .none }
                state.isLoadingPRComments = false
                state.prCommentsError = nil
                state.prCommentsResponse = response
                return .none

            case let .prCommentsFailed(message):
                state.isLoadingPRComments = false
                state.prCommentsError = message
                return .none

            case let .appendPRCommentThread(thread):
                state.detailDraft = appendPromptBlock(
                    formatPRCommentThreadPrompt(thread: thread, response: state.prCommentsResponse),
                    to: state.detailDraft
                )
                persistDetailDraft(&state)
                state.detailTab = .terminal
                state.detailInputFocusRequest += 1
                return .none

            case let .requestFixForPRCommentThread(thread):
                guard let workspace = state.selectedWorkspace else { return .none }
                let message = formatPRCommentThreadPrompt(thread: thread, response: state.prCommentsResponse)
                state.detailTab = .terminal
                state.errorMessage = nil
                return .merge(
                    sendTextEffect(state: state, workspace: workspace, message: message),
                    .cancel(id: gitPollingCancelID),
                    .cancel(id: prCommentsCancelID)
                )

        default:
            return .none
        }
    }
}
