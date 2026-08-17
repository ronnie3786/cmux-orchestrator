import Foundation
import Observation

@MainActor
@Observable
final class HerdrAppModel {
    var workspaces: [HerdrWorkspace] = []
    var alerts: [HerdrAlert] = []
    var connectionState: ConnectionState = .disconnected
    var selectedTab: AppTab = .workspaces
    var selectedWorkspaceID: String?
    var selectedPaneID: String?
    var workspacePath: [WorkspaceRoute] = []
    var isSidebarPresented = false
    var collapsedSidebarWorkspaceIDs: Set<String>
    var searchText = ""
    var filter: WorkspaceFilter = .all
    var errorMessage: String? {
        didSet { isShowingError = errorMessage != nil }
    }
    var isShowingError = false
    var toastMessage: String?
    var lastUpdated: Date?
    var isRefreshing = false
    var isSending = false
    var connectionGeneration = 0
    private(set) var activeServerConnection: ActiveServerConnection?
    var serverURLString: String
    var apiToken: String
    var isDemoMode: Bool
    var hasCompletedSetup: Bool
    var smartAlertsEnabled: Bool
    var preferPrivateTranscription: Bool
    var remotePushConfigured = false
    var remotePushDeliveryVerified = false
    var remotePushRegistrationError: String?

    @ObservationIgnored private var client: HerdrAPIClient?
    @ObservationIgnored private var pendingPushToken: String?
    @ObservationIgnored private var pendingPaneID: String?
    @ObservationIgnored private var pendingLocalAlertIDs: Set<String> = []
    @ObservationIgnored private var lastPresentedConnectionError: String?

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let defaults = UserDefaults.standard
        let forcedDemo = arguments.contains("-HerdrDemoMode")
        #if DEBUG
        let uiTestServerURL = Self.launchArgumentValue("-HerdrUITestServerURL", in: arguments)
        let uiTestToken = Self.launchArgumentValue("-HerdrUITestAPIToken", in: arguments)
            ?? Self.launchArgumentValue("-HerdrUITestToken", in: arguments)
            ?? ""
        if arguments.contains("-HerdrResetSidebarState") {
            defaults.removeObject(forKey: "herdr.sidebar.collapsedWorkspaces")
        }
        #else
        let uiTestServerURL: String? = nil
        let uiTestToken = ""
        #endif
        let bundledURL = Bundle.main.object(forInfoDictionaryKey: "HerdrDemoServerURL") as? String
        let storedURLString = uiTestServerURL
            ?? defaults.string(forKey: "herdr.serverURL")
            ?? bundledURL?.nonEmpty
            ?? "http://localhost:9092"
        let storedToken = uiTestServerURL == nil ? KeychainStore.value(for: "api-token") : uiTestToken
        serverURLString = storedURLString
        apiToken = storedToken
        isDemoMode = uiTestServerURL == nil && (forcedDemo || defaults.bool(forKey: "herdr.demoMode"))
        hasCompletedSetup = forcedDemo || uiTestServerURL != nil || defaults.bool(forKey: "herdr.completedSetup")
        smartAlertsEnabled = defaults.object(forKey: "herdr.smartAlerts") as? Bool ?? true
        preferPrivateTranscription = defaults.object(forKey: "herdr.preferPrivateTranscription") as? Bool ?? true
        collapsedSidebarWorkspaceIDs = Set(
            defaults.stringArray(forKey: "herdr.sidebar.collapsedWorkspaces") ?? []
        )

        if !isDemoMode,
           hasCompletedSetup,
           let configuration = ServerConfiguration(urlString: storedURLString, token: storedToken) {
            client = HerdrAPIClient(configuration: configuration)
            activeServerConnection = ActiveServerConnection(
                configuration: configuration,
                generation: connectionGeneration
            )
        }

        if isDemoMode {
            loadDemo()
        }
    }

    var visibleWorkspaces: [HerdrWorkspace] {
        workspaces
            .filter(matchesFilter)
            .filter(matchesSearch)
            .sorted { $0.number < $1.number }
    }

    var attentionPanes: [HerdrPane] {
        workspaces
            .flatMap(\.panes)
            .filter { $0.agentStatus.needsAttention }
            .sorted {
                if $0.agentStatus.attentionRank != $1.agentStatus.attentionRank {
                    return $0.agentStatus.attentionRank < $1.agentStatus.attentionRank
                }
                return $0.revision > $1.revision
            }
    }

    var unreadAlertCount: Int { alerts.count(where: { !$0.isRead }) }
    var workingCount: Int { workspaces.flatMap(\.panes).count(where: { $0.agentStatus == .working }) }
    var paneCount: Int { workspaces.reduce(0) { $0 + $1.paneCount } }
    var canControl: Bool { isDemoMode || connectionState == .live }
    var activeServerConfiguration: ServerConfiguration? {
        guard !isDemoMode,
              let activeServerConnection,
              activeServerConnection.generation == connectionGeneration
        else { return nil }
        return activeServerConnection.configuration
    }

    var remotePushStatusText: String {
        if let remotePushRegistrationError { return remotePushRegistrationError }
        if remotePushDeliveryVerified { return "Background delivery verified" }
        if remotePushConfigured { return "Registered, awaiting a delivery check" }
        return "Local alerts while the app is connected"
    }

    func workspace(id: String?) -> HerdrWorkspace? {
        guard let id else { return nil }
        return workspaces.first { $0.id == id }
    }

    func pane(id: String?) -> HerdrPane? {
        guard let id else { return nil }
        return workspaces.lazy.flatMap(\.panes).first { $0.id == id }
    }

    func workspace(containing pane: HerdrPane) -> HerdrWorkspace? {
        workspace(id: pane.workspaceID)
    }

    func connect() {
        guard let configuration = ServerConfiguration(urlString: serverURLString, token: apiToken) else {
            errorMessage = "Use HTTPS, or HTTP only when connecting to localhost."
            return
        }
        UserDefaults.standard.set(serverURLString, forKey: "herdr.serverURL")
        UserDefaults.standard.set(false, forKey: "herdr.demoMode")
        UserDefaults.standard.set(true, forKey: "herdr.completedSetup")
        KeychainStore.set(apiToken, for: "api-token")
        isDemoMode = false
        hasCompletedSetup = true
        errorMessage = nil
        resetConnectionState()
        connectionGeneration += 1
        client = HerdrAPIClient(configuration: configuration)
        activeServerConnection = ActiveServerConnection(
            configuration: configuration,
            generation: connectionGeneration
        )
    }

    func useDemo() {
        UserDefaults.standard.set(true, forKey: "herdr.demoMode")
        UserDefaults.standard.set(true, forKey: "herdr.completedSetup")
        isDemoMode = true
        hasCompletedSetup = true
        resetConnectionState()
        connectionGeneration += 1
        loadDemo()
    }

    func leaveDemo() {
        UserDefaults.standard.set(false, forKey: "herdr.demoMode")
        isDemoMode = false
        hasCompletedSetup = false
        resetConnectionState()
        connectionGeneration += 1
    }

    func runConnection() async {
        let generation = connectionGeneration
        if isDemoMode {
            loadDemo()
            return
        }
        guard let activeServerConnection,
              activeServerConnection.generation == generation,
              let client
        else {
            connectionState = .disconnected
            return
        }
        connectionState = .connecting
        await syncPushDevice(using: client, expectedGeneration: generation)
        var retryDelay = 2.0

        while !Task.isCancelled {
            do {
                try await refresh(using: client, expectedGeneration: generation)
                connectionState = .live
                lastPresentedConnectionError = nil
                retryDelay = 2
                for try await event in await client.events() {
                    try Task.checkCancellation()
                    guard generation == connectionGeneration else { return }
                    if event.event == "snapshot.updated" || Self.piCapabilityEvents.contains(event.event) {
                        try await refresh(
                            using: client,
                            showSpinner: false,
                            expectedGeneration: generation
                        )
                    } else if event.event == "push.delivery" {
                        await handlePushDelivery(event)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard generation == connectionGeneration else { return }
                connectionState = .failed
                let message = error.localizedDescription
                if lastPresentedConnectionError != message {
                    lastPresentedConnectionError = message
                    errorMessage = message
                }
                do {
                    try await Task.sleep(for: .seconds(retryDelay))
                } catch {
                    return
                }
                retryDelay = min(retryDelay * 2, 15)
                guard generation == connectionGeneration else { return }
                connectionState = .connecting
            }
        }
    }

    func refresh() async {
        if isDemoMode {
            loadDemo()
            return
        }
        guard let client else { return }
        let generation = connectionGeneration
        do {
            try await refresh(using: client, expectedGeneration: generation)
            connectionState = .live
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func fetchOutput(for pane: HerdrPane) async throws -> PaneOutputResponse {
        if isDemoMode {
            return PaneOutputResponse(
                ok: true,
                paneID: pane.id,
                text: DemoData.terminalText(for: pane.id),
                revision: pane.revision,
                truncated: false
            )
        }
        guard canControl, self.pane(id: pane.id) != nil, let client else {
            throw APIError.invalidResponse
        }
        return try await client.fetchPaneOutput(paneID: pane.id)
    }

    func fetchGitStatus(for workspace: HerdrWorkspace) async throws -> WorkspaceGitStatus {
        if isDemoMode { return DemoData.gitStatus(for: workspace) }
        guard canControl, self.workspace(id: workspace.id) != nil, let client else {
            throw APIError.invalidResponse
        }
        return try await client.fetchGitStatus(workspaceID: workspace.id)
    }

    func fetchGitDiff(
        for workspace: HerdrWorkspace,
        file: String,
        section: GitFileSection
    ) async throws -> WorkspaceGitDiffResponse {
        if isDemoMode { return DemoData.gitDiff(file: file, section: section) }
        guard canControl, self.workspace(id: workspace.id) != nil, let client else {
            throw APIError.invalidResponse
        }
        return try await client.fetchGitDiff(
            workspaceID: workspace.id,
            file: file,
            section: section
        )
    }

    func stageGitFile(_ file: String, in workspace: HerdrWorkspace) async throws {
        if isDemoMode {
            toastMessage = "Staged \(file)"
            return
        }
        guard canControl, self.workspace(id: workspace.id) != nil, let client else {
            throw APIError.invalidResponse
        }
        try await client.stageGitFile(workspaceID: workspace.id, file: file)
        toastMessage = "Staged \(file)"
    }

    func unstageGitFile(_ file: String, in workspace: HerdrWorkspace) async throws {
        if isDemoMode {
            toastMessage = "Unstaged \(file)"
            return
        }
        guard canControl, self.workspace(id: workspace.id) != nil, let client else {
            throw APIError.invalidResponse
        }
        try await client.unstageGitFile(workspaceID: workspace.id, file: file)
        toastMessage = "Unstaged \(file)"
    }

    func fetchSkills(for workspace: HerdrWorkspace) async throws -> SkillsResponse {
        if isDemoMode { return DemoData.skills(for: workspace) }
        guard canControl, self.workspace(id: workspace.id) != nil, let client else {
            throw APIError.invalidResponse
        }
        return try await client.fetchSkills(workspaceID: workspace.id)
    }

    func searchFiles(in workspace: HerdrWorkspace, query: String) async throws -> [ProjectFileMatch] {
        if isDemoMode { return DemoData.fileSearch(query: query, workspace: workspace).files }
        guard canControl, self.workspace(id: workspace.id) != nil, let client else {
            throw APIError.invalidResponse
        }
        return try await client.searchFiles(workspaceID: workspace.id, query: query).files
    }

    func fetchAssignedJiraTickets() async throws -> [JiraTicket] {
        if isDemoMode { return DemoData.jiraTickets.tickets }
        guard canControl, let client else { throw APIError.invalidResponse }
        return try await client.fetchAssignedJiraTickets().tickets
    }

    func fetchJiraTicket(query: String) async throws -> JiraTicket {
        if isDemoMode {
            if let ticket = DemoData.jiraTickets.tickets.first(where: {
                query.localizedCaseInsensitiveContains($0.key)
            }) ?? DemoData.jiraTickets.tickets.first {
                return ticket
            }
            throw APIError.server(status: 404, message: "Jira ticket not found.")
        }
        guard canControl, let client else { throw APIError.invalidResponse }
        let response = try await client.fetchJiraTicket(query: query)
        guard let ticket = response.ticket else {
            throw APIError.server(status: 404, message: response.error ?? "Jira ticket not found.")
        }
        return ticket
    }

    func uploadAttachment(
        from fileURL: URL,
        contentType: String,
        to workspace: HerdrWorkspace
    ) async throws -> UploadedAttachment {
        if isDemoMode {
            return UploadedAttachment(
                id: UUID().uuidString,
                filename: fileURL.lastPathComponent,
                originalFilename: fileURL.lastPathComponent,
                contentType: contentType,
                size: 0,
                path: "/tmp/herdr-demo-attachments/\(fileURL.lastPathComponent)",
                workspaceID: workspace.id,
                createdAt: ISO8601DateFormatter().string(from: .now)
            )
        }
        guard canControl, self.workspace(id: workspace.id) != nil, let client else {
            throw APIError.invalidResponse
        }
        let response = try await client.uploadAttachment(
            workspaceID: workspace.id,
            fileURL: fileURL,
            contentType: contentType
        )
        guard let attachment = response.attachment else { throw APIError.invalidResponse }
        return attachment
    }

    func setPreferPrivateTranscription(_ enabled: Bool) {
        preferPrivateTranscription = enabled
        UserDefaults.standard.set(enabled, forKey: "herdr.preferPrivateTranscription")
    }

    func transcribeVoiceNote(at fileURL: URL) async throws -> VoiceTranscription {
        if isDemoMode {
            try await Task.sleep(for: .milliseconds(350))
            return VoiceTranscription(
                text: "Review the current changes, run the focused tests, and tell me what still needs attention.",
                provider: .demo,
                language: "en",
                usedFallback: false
            )
        }

        let privateClient = preferPrivateTranscription && canControl ? client : nil
        return try await VoiceTranscriptionPipeline.run(
            preferPrivate: privateClient != nil,
            privateTranscription: {
                guard let privateClient else { throw APIError.invalidResponse }
                let response = try await privateClient.transcribeVoice(fileURL: fileURL)
                let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard response.ok, !text.isEmpty else { throw VoiceTranscriptionError.emptyTranscript }
                return VoiceTranscription(
                    text: text,
                    provider: response.backend.lowercased().contains("parakeet") ? .parakeet : .server,
                    language: response.language,
                    usedFallback: false
                )
            },
            appleTranscription: {
                let text = try await AppleVoiceTranscriber.transcribe(fileURL: fileURL)
                return VoiceTranscription(
                    text: text,
                    provider: .apple,
                    language: Locale.current.language.languageCode?.identifier,
                    usedFallback: false
                )
            }
        )
    }

    func terminalEvents(for pane: HerdrPane) async -> AsyncThrowingStream<TerminalStreamEvent, any Error>? {
        guard !isDemoMode, canControl, self.pane(id: pane.id) != nil, let client else { return nil }
        return await client.terminalEvents(paneID: pane.id)
    }

    func fetchPiConversationSnapshot(for pane: HerdrPane) async throws -> PiConversationSnapshot {
        guard !isDemoMode, canControl, self.pane(id: pane.id) != nil, let client else {
            throw APIError.invalidResponse
        }
        return try await client.fetchPiConversationSnapshot(paneID: pane.id)
    }

    func piConversationEvents(
        for pane: HerdrPane,
        after cursor: String?
    ) async -> AsyncThrowingStream<PiConversationStreamEvent, any Error>? {
        guard !isDemoMode, canControl, self.pane(id: pane.id) != nil, let client else { return nil }
        return await client.piConversationEvents(paneID: pane.id, after: cursor)
    }

    func sendPiConversationPrompt(
        _ text: String,
        disposition: PiPromptDisposition,
        to pane: HerdrPane
    ) async throws {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty,
              !isDemoMode,
              canControl,
              self.pane(id: pane.id) != nil,
              let client
        else { throw APIError.invalidResponse }
        try await client.sendPiPrompt(paneID: pane.id, text: prompt, disposition: disposition)
    }

    func abortPiConversation(for pane: HerdrPane) async throws {
        guard !isDemoMode, canControl, self.pane(id: pane.id) != nil, let client else {
            throw APIError.invalidResponse
        }
        try await client.abortPiConversation(paneID: pane.id)
    }

    func respondToPiInteraction(
        id: String,
        response: PiInteractionResponseBody,
        in pane: HerdrPane
    ) async throws {
        guard !isDemoMode, canControl, self.pane(id: pane.id) != nil, let client else {
            throw APIError.invalidResponse
        }
        try await client.respondToPiInteraction(
            paneID: pane.id,
            interactionID: id,
            response: response
        )
    }

    func fetchPiModels(for pane: HerdrPane) async throws -> PiModelCatalogResponse {
        guard !isDemoMode, canControl, self.pane(id: pane.id) != nil, let client else {
            throw APIError.invalidResponse
        }
        return try await client.fetchPiModels(paneID: pane.id)
    }

    func setPiModel(provider: String, modelID: String, for pane: HerdrPane) async throws {
        guard !isDemoMode, canControl, self.pane(id: pane.id) != nil, let client else {
            throw APIError.invalidResponse
        }
        try await client.setPiModel(paneID: pane.id, provider: provider, modelID: modelID)
    }

    func setPiThinkingLevel(level: String, for pane: HerdrPane) async throws -> String? {
        guard !isDemoMode, canControl, self.pane(id: pane.id) != nil, let client else {
            throw APIError.invalidResponse
        }
        return try await client.setPiThinkingLevel(paneID: pane.id, level: level)
    }

    func sendPrompt(_ text: String, to pane: HerdrPane) async -> Bool {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return false }
        if isDemoMode {
            toastMessage = "Sent to \(pane.displayAgentName)"
            return true
        }
        guard !isSending, canControl, self.pane(id: pane.id) != nil, let client else { return false }
        isSending = true
        defer { isSending = false }
        do {
            if pane.agentStatus == .unknown {
                try await client.sendText(toPane: pane.id, text: prompt, submit: true)
            } else {
                try await client.promptPane(id: pane.id, text: prompt)
            }
            toastMessage = "Sent to \(pane.displayAgentName)"
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func sendKeys(_ keys: [String], to pane: HerdrPane) async {
        if isDemoMode {
            toastMessage = keys.joined(separator: " + ").uppercased()
            return
        }
        guard canControl, self.pane(id: pane.id) != nil, let client else { return }
        do {
            try await client.sendKeys(toPane: pane.id, keys: keys)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func split(_ pane: HerdrPane, direction: String) async {
        await perform("Pane split") { client in
            try await client.splitPane(id: pane.id, direction: direction)
        }
    }

    func focus(_ pane: HerdrPane) async {
        await perform("Focused on Mac") { client in
            try await client.focusPane(id: pane.id)
        }
    }

    func close(_ pane: HerdrPane) async {
        await perform("Pane closed") { client in
            try await client.closePane(id: pane.id)
        }
    }

    func rename(_ pane: HerdrPane, label: String) async {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await perform("Pane renamed") { client in
            try await client.renamePane(id: pane.id, label: trimmed)
        }
    }

    func focus(_ workspace: HerdrWorkspace) async {
        await perform("Workspace focused on Mac") { client in
            try await client.focusWorkspace(id: workspace.id)
        }
    }

    func rename(_ workspace: HerdrWorkspace, label: String) async {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await perform("Workspace renamed") { client in
            try await client.renameWorkspace(id: workspace.id, label: trimmed)
        }
    }

    func close(_ workspace: HerdrWorkspace) async {
        await perform("Workspace closed") { client in
            try await client.closeWorkspace(id: workspace.id)
        }
    }

    func startAgent(in pane: HerdrPane, kind: String) async {
        let normalizedKind = kind.lowercased()
        let suffix = pane.id.replacing(":", with: "-")
        await perform("\(kind.capitalized) started") { client in
            try await client.startAgent(
                inPane: pane.id,
                name: "mobile-\(suffix)",
                kind: normalizedKind
            )
        }
    }

    func createWorkspace(label: String, cwd: String) async -> Bool {
        var succeeded = false
        await perform("Workspace created") { client in
            try await client.createWorkspace(label: label, cwd: cwd)
            succeeded = true
        }
        return succeeded
    }

    func createTab(in workspace: HerdrWorkspace) async {
        await perform("Tab created") { client in
            try await client.createTab(
                workspaceID: workspace.id,
                label: "Tab \(workspace.tabCount + 1)"
            )
        }
    }

    func markAlertRead(_ alert: HerdrAlert) async {
        if isDemoMode {
            alerts = alerts.map { item in
                guard item.id == alert.id else { return item }
                return HerdrAlert(
                    id: item.id,
                    workspaceID: item.workspaceID,
                    paneID: item.paneID,
                    status: item.status,
                    title: item.title,
                    message: item.message,
                    createdAt: item.createdAt,
                    isRead: true
                )
            }
            await NotificationManager.setBadge(unreadAlertCount)
            return
        }
        guard let client else { return }
        do {
            try await client.markAlertRead(id: alert.id)
            try await refresh(
                using: client,
                showSpinner: false,
                expectedGeneration: connectionGeneration
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearError() { errorMessage = nil }
    func clearToast() { toastMessage = nil }

    func setSmartAlerts(_ enabled: Bool) async {
        if enabled {
            let granted = await NotificationManager.requestAuthorization()
            smartAlertsEnabled = granted
            if granted {
                NotificationManager.registerForRemoteNotifications()
                await NotificationManager.postTest()
            }
        } else {
            smartAlertsEnabled = false
        }
        UserDefaults.standard.set(smartAlertsEnabled, forKey: "herdr.smartAlerts")
    }

    func prepareSmartAlerts() async {
        guard smartAlertsEnabled, hasCompletedSetup, !isDemoMode else { return }
        let granted = await NotificationManager.requestAuthorization()
        smartAlertsEnabled = granted
        UserDefaults.standard.set(granted, forKey: "herdr.smartAlerts")
        if granted {
            NotificationManager.registerForRemoteNotifications()
        }
    }

    func registerPushDevice(token: String) async {
        pendingPushToken = token
        guard let client else { return }
        await syncPushDevice(using: client, expectedGeneration: connectionGeneration)
    }

    func openPane(id paneID: String) {
        guard !paneID.isEmpty else { return }
        guard let pane = pane(id: paneID) else {
            pendingPaneID = paneID
            return
        }
        pendingPaneID = nil
        route(to: pane)
    }

    func toggleSidebarSection(_ workspaceID: String) {
        if collapsedSidebarWorkspaceIDs.contains(workspaceID) {
            collapsedSidebarWorkspaceIDs.remove(workspaceID)
        } else {
            collapsedSidebarWorkspaceIDs.insert(workspaceID)
        }
        UserDefaults.standard.set(
            Array(collapsedSidebarWorkspaceIDs),
            forKey: "herdr.sidebar.collapsedWorkspaces"
        )
    }

    func openWorkspace(id: String) {
        guard let workspace = workspace(id: id) else { return }
        isSidebarPresented = false
        selectedTab = .workspaces
        selectedWorkspaceID = id
        selectedPaneID = workspace.sortedPanes.first?.id
        workspacePath = [.workspace(id)]
    }

    func open(url: URL) {
        guard url.scheme?.lowercased() == "herdr" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryPaneID = components?.queryItems?.first {
            $0.name == "pane" || $0.name == "paneId" || $0.name == "pane_id"
        }?.value
        let pathPaneID = url.host?.lowercased() == "pane"
            ? url.pathComponents.dropFirst().first?.removingPercentEncoding
            : nil
        if let paneID = queryPaneID?.nonEmpty ?? pathPaneID?.nonEmpty {
            openPane(id: paneID)
        }
    }

    private func refresh(
        using client: HerdrAPIClient,
        showSpinner: Bool = true,
        expectedGeneration: Int
    ) async throws {
        if showSpinner { isRefreshing = true }
        defer {
            if showSpinner, expectedGeneration == connectionGeneration { isRefreshing = false }
        }
        let response = try await client.fetchWorkspaces()
        guard expectedGeneration == connectionGeneration else { throw CancellationError() }
        let previousAlertIDs = Set(alerts.map(\.id))
        workspaces = response.workspaces
        alerts = response.alerts
        lastUpdated = .now
        errorMessage = nil
        lastPresentedConnectionError = nil

        repairNavigation()
        resolvePendingPaneRoute()

        if smartAlertsEnabled && !remotePushConfigured {
            for alert in alerts where !alert.isRead && !previousAlertIDs.contains(alert.id) {
                await NotificationManager.post(alert)
            }
        }
        for alert in alerts where !alert.isRead && pendingLocalAlertIDs.contains(alert.id) {
            await NotificationManager.post(alert)
            pendingLocalAlertIDs.remove(alert.id)
        }
        await NotificationManager.setBadge(unreadAlertCount)
    }

    private func syncPushDevice(using client: HerdrAPIClient, expectedGeneration: Int) async {
        guard let token = pendingPushToken,
              activeServerConnection?.generation == expectedGeneration,
              activeServerConnection?.configuration.token.isEmpty == false
        else {
            remotePushConfigured = false
            remotePushDeliveryVerified = false
            return
        }
        let bundleID = Bundle.main.bundleIdentifier
            ?? "dev.ronnierocha.herdr-harness.herdr-harness-ios"
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        do {
            let configured = try await client.registerPushDevice(
                token: token,
                bundleID: bundleID,
                environment: environment
            )
            guard expectedGeneration == connectionGeneration else { return }
            remotePushConfigured = configured
            remotePushDeliveryVerified = false
            remotePushRegistrationError = configured
                ? nil
                : "The server has no APNs credentials, local alerts remain active"
        } catch {
            guard expectedGeneration == connectionGeneration else { return }
            remotePushConfigured = false
            remotePushDeliveryVerified = false
            remotePushRegistrationError = "Push registration failed, local alerts remain active"
        }
    }

    private func perform(
        _ successMessage: String,
        operation: (HerdrAPIClient) async throws -> Void
    ) async {
        if isDemoMode {
            toastMessage = successMessage
            return
        }
        guard canControl, let client else {
            toastMessage = "Reconnect before controlling Herdr"
            return
        }
        let generation = connectionGeneration
        do {
            try await operation(client)
            guard generation == connectionGeneration else { return }
            toastMessage = successMessage
            try await refresh(
                using: client,
                showSpinner: false,
                expectedGeneration: generation
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func matchesFilter(_ workspace: HerdrWorkspace) -> Bool {
        switch filter {
        case .all: true
        case .attention: workspace.attentionCount > 0
        case .active: workspace.workingCount > 0
        }
    }

    private static func launchArgumentValue(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
            return nil
        }
        let value = arguments[index + 1]
        return value.hasPrefix("-") ? nil : value
    }

    /// Pi can attach its semantic socket after the pane already exists. These
    /// lifecycle events are the points where workspace capability metadata can
    /// change, so refresh topology without doing so for every streamed token.
    private static let piCapabilityEvents: Set<String> = [
        "pi.bridge.connection",
        "pi.session_start",
        "pi.session_shutdown",
        "pi.session_info_changed",
        "pi.session_tree",
    ]

    private func matchesSearch(_ workspace: HerdrWorkspace) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return workspace.label.localizedStandardContains(query)
            || workspace.displayPath.localizedStandardContains(query)
            || workspace.panes.contains { $0.displayTitle.localizedStandardContains(query) }
    }

    private func loadDemo() {
        workspaces = DemoData.workspaces
        alerts = DemoData.alerts
        selectedWorkspaceID = selectedWorkspaceID ?? workspaces.first?.id
        connectionState = .demo
        lastUpdated = .now
    }

    private func resetConnectionState() {
        client = nil
        activeServerConnection = nil
        connectionState = .disconnected
        workspaces = []
        alerts = []
        selectedWorkspaceID = nil
        selectedPaneID = nil
        workspacePath = []
        isSidebarPresented = false
        lastUpdated = nil
        isRefreshing = false
        isSending = false
        remotePushConfigured = false
        remotePushDeliveryVerified = false
        remotePushRegistrationError = nil
        lastPresentedConnectionError = nil
    }

    private func repairNavigation() {
        let validWorkspaceIDs = Set(workspaces.map(\.id))
        let validPaneIDs = Set(workspaces.flatMap(\.panes).map(\.id))
        workspacePath = workspacePath.filter { route in
            switch route {
            case let .workspace(id): validWorkspaceIDs.contains(id)
            case let .pane(id): validPaneIDs.contains(id)
            }
        }
        if selectedWorkspaceID == nil || !validWorkspaceIDs.contains(selectedWorkspaceID ?? "") {
            selectedWorkspaceID = workspaces.first?.id
        }
        if let selectedPaneID, !validPaneIDs.contains(selectedPaneID) {
            self.selectedPaneID = nil
        }
        if !workspaces.isEmpty {
            let prunedCollapsed = collapsedSidebarWorkspaceIDs.intersection(validWorkspaceIDs)
            if prunedCollapsed != collapsedSidebarWorkspaceIDs {
                collapsedSidebarWorkspaceIDs = prunedCollapsed
                UserDefaults.standard.set(
                    Array(collapsedSidebarWorkspaceIDs),
                    forKey: "herdr.sidebar.collapsedWorkspaces"
                )
            }
        }
    }

    private func resolvePendingPaneRoute() {
        guard let pendingPaneID, let pane = pane(id: pendingPaneID) else { return }
        self.pendingPaneID = nil
        route(to: pane)
    }

    private func route(to pane: HerdrPane) {
        isSidebarPresented = false
        selectedTab = .workspaces
        selectedWorkspaceID = pane.workspaceID
        selectedPaneID = pane.id
        workspacePath = [.workspace(pane.workspaceID), .pane(pane.id)]
    }

    private func handlePushDelivery(_ event: HerdrEvent) async {
        guard case let .object(payload) = event.data else { return }
        let sent: Int
        if case let .number(value) = payload["sent"] { sent = Int(value) } else { sent = 0 }
        let alertID: String?
        if case let .string(value) = payload["alertId"] { alertID = value } else { alertID = nil }

        if sent > 0 {
            remotePushConfigured = true
            remotePushDeliveryVerified = true
            remotePushRegistrationError = nil
            return
        }

        remotePushConfigured = false
        remotePushDeliveryVerified = false
        remotePushRegistrationError = "APNs delivery failed, local alerts remain active"
        guard let alertID else { return }
        if let alert = alerts.first(where: { $0.id == alertID && !$0.isRead }) {
            await NotificationManager.post(alert)
        } else {
            pendingLocalAlertIDs.insert(alertID)
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
