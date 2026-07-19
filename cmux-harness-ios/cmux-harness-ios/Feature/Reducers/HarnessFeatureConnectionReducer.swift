import ComposableArchitecture
import Foundation

extension HarnessFeature {
    private func cancelRuntimeEffects() -> Effect<Action> {
        .merge(
            .cancel(id: pollingCancelID),
            .cancel(id: screenPollingCancelID),
            .cancel(id: gitPollingCancelID),
            .cancel(id: prCommentsCancelID),
            .cancel(id: fileSearchCancelID),
            .cancel(id: jiraTicketsCancelID),
            .cancel(id: jiraLookupCancelID)
        )
    }

    private func resetSessionData(_ state: inout State) {
        state.status = nil
        state.workspaces = []
        state.logEntries = []
        state.notifications = []
        state.feedItems = []
        state.isRefreshing = false
        state.lastUpdated = nil
        state.sessionSearchText = ""
        state.sessionFilter = .all
        state.selectedWorkspaceID = nil
        state.detailTab = .terminal
        state.fullScreenText = nil
        state.draftMessages = [:]
        state.detailDrafts = state.isDemoMode ? [:] : HarnessSettingsStore.detailDrafts
        state.detailDraft = ""
        state.pendingPushApproval = nil
        state.isShowingNewSession = false
        state.isCreatingSession = false
        state.quickSessionCreation = nil
        state.pendingCreatedWorkspaceSelection = nil
        state.renameWorkspaceID = nil
        state.renameText = ""
        state.gitStatus = nil
        state.gitError = nil
        state.isLoadingGit = false
        state.gitSegment = .status
        state.diffSheet = nil
        state.prCommentsResponse = nil
        state.prCommentsError = nil
        state.isLoadingPRComments = false
        state.includeResolvedPRComments = false
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
    }

    private func activateServerSource(
        _ source: HarnessServerSource,
        in state: inout State,
        setupMessage: String
    ) -> Effect<Action> {
        let shouldResetSessionData = state.isDemoMode || state.committedServerURLString != source.urlString
        state.isDemoMode = false
        HarnessSettingsStore.isLocalDemoMode = false
        HarnessSettingsStore.selectedServerSourceID = source.id
        state.serverSources = HarnessSettingsStore.serverSources
        state.selectedServerSourceID = source.id
        state.editingServerSourceID = source.id
        state.serverSourceNameString = source.name
        state.serverURLString = source.urlString
        state.committedServerURLString = source.urlString
        state.isShowingSettings = false
        state.errorMessage = nil
        state.serverSetupError = nil
        state.serverSetupMessage = setupMessage

        if shouldResetSessionData {
            resetSessionData(&state)
            HarnessSettingsStore.lastSelectedWorkspaceID = nil
        }

        return .merge(
            cancelRuntimeEffects(),
            configuredStartupEffects(state: state)
        )
    }

    private func clearActiveServerSource(in state: inout State, setupMessage: String?) -> Effect<Action> {
        state.selectedServerSourceID = nil
        state.editingServerSourceID = nil
        state.serverSourceNameString = ""
        state.serverURLString = ""
        state.committedServerURLString = ""
        state.isShowingSettings = false
        state.errorMessage = nil
        state.serverSetupError = nil
        state.serverSetupMessage = setupMessage
        resetSessionData(&state)
        HarnessSettingsStore.lastSelectedWorkspaceID = nil

        return .merge(
            cancelRuntimeEffects(),
            .send(.discoverServer)
        )
    }

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
                return cancelRuntimeEffects()

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
                        async let notifs = client.notifications(baseURLString)
                        let feed = FeedResponse(ok: true, items: [], error: nil)
                        let payload = try await RefreshPayload(
                            status: status,
                            log: log,
                            feed: feed,
                            notifications: notifs
                        )
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
                state.notifications = payload.notifications.notifications
                state.feedItems = payload.feed.items
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

            case .newServerSourceTapped:
                state.editingServerSourceID = nil
                state.serverSourceNameString = ""
                state.serverURLString = ""
                return .none

            case let .editServerSource(id):
                guard let source = state.serverSources.first(where: { $0.id == id }) else {
                    return .none
                }
                state.editingServerSourceID = source.id
                state.serverSourceNameString = source.name
                state.serverURLString = source.urlString
                return .none

            case let .selectServerSource(id):
                guard let source = state.serverSources.first(where: { $0.id == id }) else {
                    return .none
                }
                return activateServerSource(
                    source,
                    in: &state,
                    setupMessage: "Switched to \(source.name)."
                )

            case let .deleteServerSource(id):
                let wasSelected = state.selectedServerSourceID == id
                HarnessSettingsStore.deleteServerSource(id: id)
                state.serverSources = HarnessSettingsStore.serverSources
                state.selectedServerSourceID = HarnessSettingsStore.selectedServerSourceID

                if state.editingServerSourceID == id {
                    state.editingServerSourceID = state.selectedServerSourceID
                    if let source = state.activeServerSource {
                        state.serverSourceNameString = source.name
                        state.serverURLString = source.urlString
                    } else {
                        state.serverSourceNameString = ""
                        state.serverURLString = ""
                    }
                }

                guard wasSelected else {
                    return .none
                }

                guard let nextSource = state.activeServerSource else {
                    return clearActiveServerSource(
                        in: &state,
                        setupMessage: "Server source removed. Looking for a cmux harness server..."
                    )
                }

                return activateServerSource(
                    nextSource,
                    in: &state,
                    setupMessage: "Removed server source. Switched to \(nextSource.name)."
                )

            case .saveServerTapped:
                guard let source = HarnessSettingsStore.saveServerSource(
                    id: state.editingServerSourceID,
                    name: state.serverSourceNameString,
                    urlString: state.serverURLString
                ) else {
                    state.serverSetupError = "Server URL is required."
                    state.errorMessage = "Server URL is required."
                    return .none
                }
                state.serverSources = HarnessSettingsStore.serverSources
                return activateServerSource(
                    source,
                    in: &state,
                    setupMessage: "Saved \(source.name)."
                )

            case .startLocalDemoTapped:
                state.isDemoMode = true
                HarnessSettingsStore.isLocalDemoMode = true
                state.committedServerURLString = HarnessLocalDemo.baseURL
                state.isShowingSettings = false
                state.errorMessage = nil
                state.serverSetupError = nil
                state.serverSetupMessage = "Local demo mode is running on this iPhone."
                state.discoveredServers = []
                resetSessionData(&state)
                HarnessSettingsStore.lastSelectedWorkspaceID = nil
                return configuredStartupEffects(state: state)

            case .exitDemoModeTapped:
                state.isDemoMode = false
                HarnessSettingsStore.isLocalDemoMode = false
                state.serverSources = HarnessSettingsStore.serverSources
                if let source = state.activeServerSource {
                    return activateServerSource(
                        source,
                        in: &state,
                        setupMessage: "Demo closed. Connecting to \(source.name)."
                    )
                } else {
                    return clearActiveServerSource(
                        in: &state,
                        setupMessage: "Demo closed. Looking for your cmux harness server..."
                    )
                }

            case .useDemoServerTapped:
                let normalized = HarnessAPI.normalizedBaseURL(state.demoServerURLString)
                guard !normalized.isEmpty else {
                    state.serverSetupError = "Demo server URL is not configured for this build."
                    state.errorMessage = "Demo server URL is not configured for this build."
                    return .none
                }
                guard let source = HarnessSettingsStore.saveServerSource(
                    id: nil,
                    name: "Demo Server",
                    urlString: normalized
                ) else {
                    return .none
                }
                return activateServerSource(
                    source,
                    in: &state,
                    setupMessage: "Connected to demo server."
                )

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
                let sourceName = server.source == .tailscale ? "Tailscale" : "LAN"
                guard let source = HarnessSettingsStore.saveServerSource(
                    id: nil,
                    name: server.name,
                    urlString: normalized
                ) else {
                    return .none
                }
                state.isDiscoveringServer = false
                state.discoveredServers = []
                return activateServerSource(
                    source,
                    in: &state,
                    setupMessage: "Connected with \(sourceName): \(normalized)"
                )

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

            case let .replyToFeed(requestID, kind, action, mode, selections):
                return .run { [client = self.harnessClient, baseURLString = state.committedServerURLString] send in
                    do {
                        _ = try await client.replyToFeed(baseURLString, requestID, kind, action, mode, selections)
                        await send(.feedReplySucceeded(requestID))
                        await send(.refresh)
                    } catch {
                        await send(.requestFailed(HarnessAPI.message(for: error)))
                    }
                }

            case let .feedReplySucceeded(requestID):
                state.feedItems.removeAll { $0.requestID == requestID }
                return .none

        default:
            return .none
        }
    }
}
