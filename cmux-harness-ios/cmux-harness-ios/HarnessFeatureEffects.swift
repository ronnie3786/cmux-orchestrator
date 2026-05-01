import ComposableArchitecture
import Foundation

extension HarnessFeature {
    func configuredStartupEffects(state: State) -> Effect<Action> {
        var effects: [Effect<Action>] = [
            .send(.refresh),
            .run { [clock = self.clock] send in
                while !Task.isCancelled {
                    try? await clock.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    await send(.refresh)
                }
            }
            .cancellable(id: pollingCancelID, cancelInFlight: true)
        ]
        if state.selectedWorkspaceID != nil {
            effects.append(screenPollingEffect())
            if state.detailTab == .git {
                if state.gitSegment == .prComments {
                    effects.append(.send(.loadPRComments))
                } else {
                    effects.append(gitPollingEffect())
                }
            }
        }
        return .merge(effects)
    }

    func discoverServerEffect(tailscaleHost: String) -> Effect<Action> {
        .run { [client = self.harnessClient, tailscaleHost] send in
            let host = tailscaleHost.trimmingCharacters(in: .whitespacesAndNewlines)
            if !host.isEmpty {
                let tailscaleURL = HarnessAPI.harnessURLFromHost(host)
                if await client.probeServer(tailscaleURL) {
                    await send(.useDiscoveredServer(DiscoveredHarnessServer(
                        name: "Tailscale",
                        urlString: tailscaleURL,
                        source: .tailscale
                    )))
                    return
                }
            }

            let discovered = await client.discoverServers()
            if let first = discovered.first {
                await send(.useDiscoveredServer(first))
            } else {
                await send(.serverDiscoverySucceeded(discovered))
            }
        }
    }

    func screenPollingEffect() -> Effect<Action> {
        .run { [clock = self.clock] send in
            while !Task.isCancelled {
                try? await clock.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                await send(.screenTick)
            }
        }
        .cancellable(id: screenPollingCancelID, cancelInFlight: true)
    }

    func gitPollingEffect() -> Effect<Action> {
        .run { [clock = self.clock] send in
            while !Task.isCancelled {
                try? await clock.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await send(.gitTick)
            }
        }
        .cancellable(id: gitPollingCancelID, cancelInFlight: true)
    }

    func createSessionEffect(
        state: State,
        projectPath: String,
        branchName: String,
        jiraURL: String,
        prompt: String,
        mode: NewSessionMode,
        sessionName: String
    ) -> Effect<Action> {
        .run { [client = self.harnessClient, baseURLString = state.committedServerURLString] send in
            do {
                let response = try await client.createSession(
                    baseURLString,
                    projectPath,
                    branchName,
                    jiraURL,
                    prompt,
                    mode,
                    sessionName
                )
                await send(.createNewSessionSucceeded(response))
            } catch {
                await send(.createNewSessionFailed(HarnessAPI.message(for: error)))
            }
        }
    }

    func sendTextEffect(state: State, workspace: Workspace, message: String) -> Effect<Action> {
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

    func uploadAttachmentEffect(
        state: State,
        workspace: Workspace,
        attachment: TerminalAttachment
    ) -> Effect<Action> {
        .run { [client = self.harnessClient, baseURLString = state.committedServerURLString, workspace, attachment] send in
            do {
                let response = try await client.uploadAttachment(
                    baseURLString,
                    workspace.index,
                    workspace.uuid,
                    attachment.sourceURL,
                    attachment.filename
                )
                await send(.attachmentUploadSucceeded(
                    workspaceID: workspace.id,
                    attachmentID: attachment.id,
                    response
                ))
            } catch {
                await send(.attachmentUploadFailed(
                    workspaceID: workspace.id,
                    attachmentID: attachment.id,
                    HarnessAPI.message(for: error)
                ))
            }
        }
    }

    func clearPushApprovalEffect(state: State, workspace: Workspace) -> Effect<Action> {
        .run { [client = self.harnessClient, baseURLString = state.committedServerURLString, workspace] _ in
            _ = try? await client.clearPushApproval(
                baseURLString,
                workspace.pushWorkspaceID,
                workspace.uuid,
                workspace.surfaceId
            )
        }
    }
}

let pollingCancelID = "cmux-harness-ios.polling"
let screenPollingCancelID = "cmux-harness-ios.screen-polling"
let gitPollingCancelID = "cmux-harness-ios.git-polling"
let prCommentsCancelID = "cmux-harness-ios.pr-comments"
let fileSearchCancelID = "cmux-harness-ios.file-search"
let jiraTicketsCancelID = "cmux-harness-ios.jira-tickets"
let jiraLookupCancelID = "cmux-harness-ios.jira-lookup"
