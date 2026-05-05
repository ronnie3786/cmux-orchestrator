import ComposableArchitecture
import Foundation

extension HarnessFeature {
    func reduceConnection(into state: inout State, action: Action) -> Effect<Action> {
        switch action {
            case .binding:
                persistDetailDraft(&state)
                return .none

            case .onAppear:
                guard state.isServerConfigured else {
                    return .send(.discoverServer)
                }
                return configuredStartupEffects(state: state)

            case .onDisappear:
                return .merge(
                    .cancel(id: pollingCancelID),
                    .cancel(id: screenPollingCancelID),
                    .cancel(id: gitPollingCancelID),
                    .cancel(id: prCommentsCancelID),
                    .cancel(id: fileSearchCancelID),
                    .cancel(id: jiraTicketsCancelID)
                )

            case .refresh:
                guard state.isServerConfigured else {
                    state.isRefreshing = false
                    return .none
                }
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
                if let pendingPushApproval = state.pendingPushApproval,
                   let workspaceID = matchingWorkspaceID(for: pendingPushApproval, in: state) {
                    state.pendingPushApproval = nil
                    return .send(.selectWorkspace(workspaceID))
                }
                if let pendingSelection = state.pendingCreatedWorkspaceSelection,
                   let workspaceID = matchingWorkspaceID(for: pendingSelection, in: state) {
                    state.pendingCreatedWorkspaceSelection = nil
                    state.quickSessionCreation = nil
                    state.sessionSearchText = ""
                    state.sessionFilter = .all
                    return .send(.selectWorkspace(workspaceID))
                }
                if let selected = state.selectedWorkspaceID,
                   !state.workspaces.contains(where: { $0.id == selected }) {
                    persistDetailDraft(&state)
                    state.selectedWorkspaceID = nil
                    HarnessSettingsStore.lastSelectedWorkspaceID = nil
                    state.fullScreenText = nil
                    state.gitStatus = nil
                    state.gitSegment = .status
                    state.prCommentsResponse = nil
                    state.prCommentsError = nil
                    state.isLoadingPRComments = false
                    state.includeResolvedPRComments = false
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
                    state.isShowingJiraTickets = false
                    state.jiraTickets = []
                    state.jiraTicketsError = nil
                    state.isLoadingJiraTickets = false
                    state.jiraLookupQuery = ""
                    state.resolvedJiraTicket = nil
                    state.jiraLookupError = nil
                    state.isResolvingJiraTicket = false
                    state.terminalAttachments = [:]
                    return .merge(
                        .cancel(id: screenPollingCancelID),
                        .cancel(id: gitPollingCancelID),
                        .cancel(id: prCommentsCancelID),
                        .cancel(id: fileSearchCancelID),
                        .cancel(id: jiraTicketsCancelID),
                        .cancel(id: jiraLookupCancelID)
                    )
                }
                return .none

            case let .refreshFailed(message):
                state.isRefreshing = false
                state.errorMessage = message
                return .none

            case .saveServerTapped:
                let normalized = HarnessAPI.normalizedBaseURL(state.serverURLString)
                guard !normalized.isEmpty else {
                    state.serverSetupError = "Server URL is required."
                    state.errorMessage = "Server URL is required."
                    return .none
                }
                state.serverURLString = normalized
                state.committedServerURLString = normalized
                HarnessSettingsStore.serverURL = normalized
                state.isShowingSettings = false
                state.errorMessage = nil
                state.serverSetupError = nil
                state.serverSetupMessage = "Saved \(normalized)"
                return configuredStartupEffects(state: state)

            case .useDemoServerTapped:
                let normalized = HarnessAPI.normalizedBaseURL(state.demoServerURLString)
                guard !normalized.isEmpty else {
                    state.serverSetupError = "Demo server URL is not configured for this build."
                    state.errorMessage = "Demo server URL is not configured for this build."
                    return .none
                }
                state.serverURLString = normalized
                state.committedServerURLString = normalized
                HarnessSettingsStore.serverURL = normalized
                state.isShowingSettings = false
                state.errorMessage = nil
                state.serverSetupError = nil
                state.serverSetupMessage = "Connected to demo server."
                return configuredStartupEffects(state: state)

            case .discoverServer:
                guard !state.isDiscoveringServer else { return .none }
                state.isDiscoveringServer = true
                state.serverSetupError = nil
                state.serverSetupMessage = "Looking for a running cmux harness server..."
                return discoverServerEffect(tailscaleHost: state.tailscaleHostString)

            case let .serverDiscoverySucceeded(servers):
                state.isDiscoveringServer = false
                state.discoveredServers = servers
                if servers.isEmpty {
                    state.serverSetupMessage = nil
                    state.serverSetupError = "No running server was found. Start dashboard.py on your Mac, or enter the URL manually."
                } else {
                    state.serverSetupMessage = "Found \(servers.count) server\(servers.count == 1 ? "" : "s")."
                    state.serverSetupError = nil
                }
                return .none

            case let .serverDiscoveryFailed(message):
                state.isDiscoveringServer = false
                state.serverSetupMessage = nil
                state.serverSetupError = message
                return .none

            case let .useDiscoveredServer(server):
                let normalized = HarnessAPI.normalizedBaseURL(server.urlString)
                guard !normalized.isEmpty else { return .none }
                state.serverURLString = normalized
                state.committedServerURLString = normalized
                HarnessSettingsStore.serverURL = normalized
                state.isDiscoveringServer = false
                state.discoveredServers = []
                state.serverSetupError = nil
                let sourceName = server.source == .tailscale ? "Tailscale" : "LAN"
                state.serverSetupMessage = "Connected with \(sourceName): \(normalized)"
                return configuredStartupEffects(state: state)

            case .probeTailscaleHostTapped:
                let host = state.tailscaleHostString.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !host.isEmpty else {
                    state.serverSetupError = "Enter your Mac's Tailscale MagicDNS host first."
                    return .none
                }
                HarnessSettingsStore.tailscaleHost = host
                state.tailscaleHostString = host
                state.isDiscoveringServer = true
                state.serverSetupError = nil
                state.serverSetupMessage = "Checking Tailscale host..."
                return .run { [client = self.harnessClient, urlString = HarnessAPI.harnessURLFromHost(host)] send in
                    let ok = await client.probeServer(urlString)
                    if ok {
                        await send(.tailscaleProbeSucceeded(urlString))
                    } else {
                        await send(.tailscaleProbeFailed("Could not reach \(urlString). Confirm Tailscale is connected on both devices and the server is running."))
                    }
                }

            case let .tailscaleProbeSucceeded(urlString):
                state.isDiscoveringServer = false
                return .send(.useDiscoveredServer(DiscoveredHarnessServer(
                    name: "Tailscale",
                    urlString: urlString,
                    source: .tailscale
                )))

            case let .tailscaleProbeFailed(message):
                state.isDiscoveringServer = false
                state.serverSetupMessage = nil
                state.serverSetupError = message
                return .none

            case .clearError:
                state.errorMessage = nil
                state.serverSetupError = nil
                return .none

        default:
            return .none
        }
    }
}
