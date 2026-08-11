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
    var serverURLString: String
    var apiToken: String
    var isDemoMode: Bool
    var hasCompletedSetup: Bool
    var smartAlertsEnabled: Bool
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
        let bundledURL = Bundle.main.object(forInfoDictionaryKey: "HerdrDemoServerURL") as? String
        serverURLString = defaults.string(forKey: "herdr.serverURL")
            ?? bundledURL?.nonEmpty
            ?? "http://localhost:9092"
        apiToken = KeychainStore.value(for: "api-token")
        isDemoMode = forcedDemo || defaults.bool(forKey: "herdr.demoMode")
        hasCompletedSetup = forcedDemo || defaults.bool(forKey: "herdr.completedSetup")
        smartAlertsEnabled = defaults.object(forKey: "herdr.smartAlerts") as? Bool ?? true

        if isDemoMode {
            loadDemo()
        }
    }

    var visibleWorkspaces: [HerdrWorkspace] {
        workspaces
            .filter(matchesFilter)
            .filter(matchesSearch)
            .sorted {
                if $0.agentStatus.attentionRank != $1.agentStatus.attentionRank {
                    return $0.agentStatus.attentionRank < $1.agentStatus.attentionRank
                }
                return $0.number < $1.number
            }
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
        guard ServerConfiguration(urlString: serverURLString, token: apiToken) != nil else {
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
        guard let configuration = ServerConfiguration(urlString: serverURLString, token: apiToken) else {
            connectionState = .disconnected
            return
        }

        let client = HerdrAPIClient(configuration: configuration)
        guard generation == connectionGeneration else { return }
        self.client = client
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
                    if event.event == "snapshot.updated" {
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

    func terminalFrames(for pane: HerdrPane) async -> AsyncThrowingStream<TerminalFrame, any Error>? {
        guard !isDemoMode, canControl, self.pane(id: pane.id) != nil, let client else { return nil }
        return await client.terminalFrames(paneID: pane.id)
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
        guard let token = pendingPushToken, !apiToken.isEmpty else {
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
        connectionState = .disconnected
        workspaces = []
        alerts = []
        selectedWorkspaceID = nil
        selectedPaneID = nil
        workspacePath = []
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
    }

    private func resolvePendingPaneRoute() {
        guard let pendingPaneID, let pane = pane(id: pendingPaneID) else { return }
        self.pendingPaneID = nil
        route(to: pane)
    }

    private func route(to pane: HerdrPane) {
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
