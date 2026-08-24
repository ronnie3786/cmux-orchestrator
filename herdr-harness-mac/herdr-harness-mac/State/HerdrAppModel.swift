import Foundation
import Observation

@MainActor
@Observable
final class HerdrAppModel {
    struct MachineRuntime {
        var client: HerdrAPIClient?
        var connection: ActiveServerConnection?
        var state: ConnectionState = .disconnected
        var lastUpdated: Date?
        var lastError: String?
        var firstFailureAt: Date?
        var lastRefreshCompletedAt: ContinuousClock.Instant?
        var pendingRefresh = false
        var deferredRefreshTask: Task<Void, Never>?
        var lastEventID: Int?
        var didSweepDelivered = false
    }

    var workspaces: [HerdrWorkspace] = []
    var alerts: [HerdrAlert] = []
    var connectionState: ConnectionState = .disconnected
    var selectedTab: AppTab = .workspaces
    var selectedWorkspaceID: String?
    var selectedPaneID: String?
    var workspacePath: [WorkspaceRoute] = []
    var isSidebarPresented = false
    var collapsedSidebarWorkspaceIDs: Set<String>
    var collapsedSidebarMachineIDs: Set<String>
    var collapsedSidebarTabIDs: Set<String>
    var starredChatIDs: Set<String>
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
    var connectionGeneration = 0 {
        didSet {
            if connectionGeneration != oldValue { cancelDeferredRefreshes() }
        }
    }
    private(set) var activeServerConnection: ActiveServerConnection?
    var machineStates: [String: ConnectionState] = [:]
    var machines: [HerdrMachine]
    var machineScope: MachineScope
    var serverURLString: String
    var apiToken: String
    var isDemoMode: Bool
    var hasCompletedSetup: Bool
    var smartAlertsEnabled: Bool
    var preferPrivateTranscription: Bool
    var remotePushConfigured = false
    var remotePushDeliveryVerified = false
    var remotePushRegistrationError: String?
    let cleanupPresenter = CleanupSheetPresenter()

    private let userDefaults: UserDefaults
    @ObservationIgnored private var runtimes: [String: MachineRuntime] = [:]
    @ObservationIgnored private var pendingPushToken: String?
    @ObservationIgnored private var pendingPaneID: String?
    @ObservationIgnored private var pendingLocalAlertIDs: Set<String> = []
    @ObservationIgnored private var lastPresentedConnectionError: String?
    @ObservationIgnored private var lastBadgeCount: Int?
    /// Internal test seam for deterministic URLProtocol-backed clients.
    @ObservationIgnored var clientFactory: (ServerConfiguration) -> HerdrAPIClient = {
        HerdrAPIClient(configuration: $0)
    }
    @ObservationIgnored var fleetRefreshRetryBase: Duration = .seconds(2)
    private static let connectionFailureGrace: TimeInterval = 10
    private static let fleetRefreshWindow = Duration.milliseconds(200)

    init(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        userDefaults: UserDefaults = .standard
    ) {
        self.userDefaults = userDefaults
        let defaults = userDefaults
        let forcedDemo = arguments.contains("-HerdrDemoMode")
        #if DEBUG
        let uiTestServerURL = Self.launchArgumentValue("-HerdrUITestServerURL", in: arguments)
        let uiTestToken = Self.launchArgumentValue("-HerdrUITestAPIToken", in: arguments)
            ?? Self.launchArgumentValue("-HerdrUITestToken", in: arguments)
            ?? ""
        if arguments.contains("-HerdrResetSidebarState") {
            defaults.removeObject(forKey: "herdr.sidebar.collapsedWorkspaces")
            defaults.removeObject(forKey: "herdr.sidebar.collapsedTabs")
            defaults.removeObject(forKey: "herdr.sidebar.starredChats")
        }
        #else
        let uiTestServerURL: String? = nil
        let uiTestToken = ""
        #endif
        Self.migrateMachinesIfNeeded(defaults: defaults)
        let bundledURL = Bundle.main.object(forInfoDictionaryKey: "HerdrDemoServerURL") as? String
        let persistedMachines = Self.loadMachines(defaults: defaults)
        machines = uiTestServerURL.map {
            [HerdrMachine(id: "ui-test", name: Self.machineName(for: $0), urlString: $0)]
        } ?? persistedMachines
        machineScope = MachineScope.load(from: defaults)
        let primaryMachine = persistedMachines.first
        let storedURLString = uiTestServerURL
            ?? primaryMachine?.urlString
            ?? bundledURL?.nonEmpty
            ?? "http://localhost:9092"
        let storedToken = uiTestServerURL == nil
            ? primaryMachine.map { KeychainStore.value(for: "api-token.\($0.id)") } ?? ""
            : uiTestToken
        serverURLString = storedURLString
        apiToken = storedToken
        isDemoMode = uiTestServerURL == nil && (forcedDemo || defaults.bool(forKey: "herdr.demoMode"))
        hasCompletedSetup = forcedDemo || uiTestServerURL != nil || defaults.bool(forKey: "herdr.completedSetup")
        smartAlertsEnabled = defaults.object(forKey: "herdr.smartAlerts") as? Bool ?? true
        preferPrivateTranscription = defaults.object(forKey: "herdr.preferPrivateTranscription") as? Bool ?? true
        collapsedSidebarWorkspaceIDs = Set(
            defaults.stringArray(forKey: "herdr.sidebar.collapsedWorkspaces") ?? []
        )
        collapsedSidebarMachineIDs = Set(
            defaults.stringArray(forKey: "herdr.sidebar.collapsedMachines") ?? []
        )
        collapsedSidebarTabIDs = Set(
            defaults.stringArray(forKey: "herdr.sidebar.collapsedTabs") ?? []
        )
        starredChatIDs = Set(defaults.stringArray(forKey: "herdr.sidebar.starredChats") ?? [])

        if case let .machine(id) = machineScope, !persistedMachines.contains(where: { $0.id == id }) {
            machineScope = .all
        }

        if !isDemoMode, hasCompletedSetup {
            for machine in machines {
                let token = machine.id == "ui-test" ? uiTestToken : KeychainStore.value(for: "api-token.\(machine.id)")
                guard let configuration = ServerConfiguration(urlString: machine.urlString, token: token) else { continue }
                let connection = ActiveServerConnection(configuration: configuration, generation: connectionGeneration)
                runtimes[machine.id] = MachineRuntime(
                    client: clientFactory(configuration),
                    connection: connection
                )
                machineStates[machine.id] = .disconnected
            }
            updateAggregateConnectionState()
            mirrorPrimaryConnection()
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

    func canControl(machineID: String) -> Bool {
        isDemoMode || connectionState(forMachine: machineID) == .live
    }

    func connectionState(forMachine id: String) -> ConnectionState {
        machineStates[id] ?? (isDemoMode ? .demo : .disconnected)
    }

    func setMachineScope(_ scope: MachineScope) {
        machineScope = scope
        scope.save(to: userDefaults)
    }
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
        workspaces.first { $0.machineID == pane.machineID && $0.workspaceID == pane.workspaceID }
    }

    func connect() {
        guard let configuration = ServerConfiguration(urlString: serverURLString, token: apiToken) else {
            errorMessage = "Use HTTPS, or HTTP only when connecting to localhost."
            return
        }
        if isDemoMode {
            machines = Self.loadMachines(defaults: userDefaults)
        }
        let name = Self.machineName(for: serverURLString)
        let machine: HerdrMachine
        if let first = machines.first {
            machine = HerdrMachine(id: first.id, name: first.name.isEmpty ? name : first.name, urlString: serverURLString)
            machines[0] = machine
        } else {
            machine = HerdrMachine(id: UUID().uuidString, name: name, urlString: serverURLString)
            machines = [machine]
        }
        persistMachines()
        userDefaults.set(serverURLString, forKey: "herdr.serverURL")
        UserDefaults.standard.set(false, forKey: "herdr.demoMode")
        UserDefaults.standard.set(true, forKey: "herdr.completedSetup")
        KeychainStore.set(apiToken, for: "api-token.\(machine.id)")
        isDemoMode = false
        hasCompletedSetup = true
        errorMessage = nil
        resetConnectionState()
        connectionGeneration += 1
        runtimes[machine.id] = MachineRuntime(
            client: clientFactory(configuration),
            connection: ActiveServerConnection(configuration: configuration, generation: connectionGeneration)
        )
        machineStates[machine.id] = .disconnected
        mirrorPrimaryConnection()
        let generation = connectionGeneration
        Task { [weak self] in
            await self?.autoNameFromNetwork(machineID: machine.id, expectedName: name, generation: generation)
        }
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
        machines = Self.loadMachines(defaults: userDefaults)
        if let primary = machines.first {
            serverURLString = primary.urlString
            apiToken = KeychainStore.value(for: "api-token.\(primary.id)")
        }
        resetConnectionState()
        connectionGeneration += 1
    }

    @discardableResult
    func addMachine(name: String, urlString: String, token: String) -> Bool {
        guard ServerConfiguration(urlString: urlString, token: token) != nil else {
            errorMessage = "Use HTTPS, or HTTP only when connecting to localhost."
            return false
        }
        leaveDemoForMachineManagementIfNeeded()
        let machine = HerdrMachine(
            id: UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? Self.machineName(for: urlString),
            urlString: urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        machines.append(machine)
        persistMachines()
        KeychainStore.set(token, for: "api-token.\(machine.id)")
        hasCompletedSetup = true
        UserDefaults.standard.set(true, forKey: "herdr.completedSetup")
        errorMessage = nil
        connectionGeneration += 1
        return true
    }

    @discardableResult
    func updateMachine(id: String, name: String, urlString: String, token: String) -> Bool {
        guard ServerConfiguration(urlString: urlString, token: token) != nil else {
            errorMessage = "Use HTTPS, or HTTP only when connecting to localhost."
            return false
        }
        guard let index = machines.firstIndex(where: { $0.id == id }) else {
            errorMessage = "Machine not found."
            return false
        }
        machines[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? Self.machineName(for: urlString)
        machines[index].urlString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        persistMachines()
        KeychainStore.set(token, for: "api-token.\(id)")
        if machines.first?.id == id {
            serverURLString = machines[index].urlString
            apiToken = token
        }
        errorMessage = nil
        connectionGeneration += 1
        return true
    }

    func reorderMachines(from source: IndexSet, to destination: Int) {
        let moving = source.map { machines[$0] }
        for index in source.sorted(by: >) {
            machines.remove(at: index)
        }
        let insertionIndex = destination - source.count(where: { $0 < destination })
        machines.insert(contentsOf: moving, at: insertionIndex)
        persistMachines()
        mirrorPrimaryConnection()
    }

    func runConnection() async {
        let generation = connectionGeneration
        if isDemoMode {
            loadDemo()
            return
        }
        guard !machines.isEmpty else {
            connectionState = .disconnected
            return
        }
        for machine in machines { prepareRuntime(for: machine, generation: generation) }
        updateAggregateConnectionState()
        await withTaskGroup(of: Void.self) { group in
            for machine in machines {
                group.addTask {
                    await self.runMachineConnection(machine: machine, expectedGeneration: generation)
                }
            }
        }
    }

    func noteConnectionFailure(machineID: String, now: Date) -> Bool {
        var runtime = runtimes[machineID] ?? MachineRuntime()
        guard let firstFailureAt = runtime.firstFailureAt else {
            runtime.firstFailureAt = now
            runtimes[machineID] = runtime
            return false
        }
        runtimes[machineID] = runtime
        return now.timeIntervalSince(firstFailureAt) >= Self.connectionFailureGrace
    }

    func refresh() async {
        if isDemoMode {
            loadDemo()
            return
        }
        let generation = connectionGeneration
        for machine in machines {
            guard let client = client(forMachine: machine.id) else { continue }
            do {
                try await refresh(machineID: machine.id, using: client, expectedGeneration: generation)
                setRuntimeState(.live, for: machine.id)
            } catch {
                guard generation == connectionGeneration else { return }
                setRuntimeState(.failed, for: machine.id, error: error.localizedDescription)
            }
        }
    }

    func fetchOutput(for pane: HerdrPane) async throws -> PaneOutputResponse {
        if isDemoMode {
            return PaneOutputResponse(
                ok: true,
                paneID: pane.paneID,
                text: DemoData.terminalText(for: pane.id),
                revision: pane.revision,
                truncated: false
            )
        }
        guard canControl(machineID: pane.machineID), self.pane(id: pane.id) != nil,
              let client = client(forMachine: pane.machineID) else {
            throw APIError.invalidResponse
        }
        return try await client.fetchPaneOutput(paneID: pane.paneID)
    }

    func fetchGitStatus(for workspace: HerdrWorkspace) async throws -> WorkspaceGitStatus {
        if isDemoMode { return DemoData.gitStatus(for: workspace) }
        guard canControl(machineID: workspace.machineID), self.workspace(id: workspace.id) != nil,
              let client = client(forMachine: workspace.machineID) else {
            throw APIError.invalidResponse
        }
        return try await client.fetchGitStatus(workspaceID: workspace.workspaceID)
    }

    func fetchGitDiff(
        for workspace: HerdrWorkspace,
        file: String,
        section: GitFileSection
    ) async throws -> WorkspaceGitDiffResponse {
        if isDemoMode { return DemoData.gitDiff(file: file, section: section) }
        guard canControl(machineID: workspace.machineID), self.workspace(id: workspace.id) != nil,
              let client = client(forMachine: workspace.machineID) else {
            throw APIError.invalidResponse
        }
        return try await client.fetchGitDiff(
            workspaceID: workspace.workspaceID,
            file: file,
            section: section
        )
    }

    func stageGitFile(_ file: String, in workspace: HerdrWorkspace) async throws {
        if isDemoMode {
            toastMessage = "Staged \(file)"
            return
        }
        guard canControl(machineID: workspace.machineID), self.workspace(id: workspace.id) != nil,
              let client = client(forMachine: workspace.machineID) else {
            throw APIError.invalidResponse
        }
        try await client.stageGitFile(workspaceID: workspace.workspaceID, file: file)
        toastMessage = "Staged \(file)"
    }

    func unstageGitFile(_ file: String, in workspace: HerdrWorkspace) async throws {
        if isDemoMode {
            toastMessage = "Unstaged \(file)"
            return
        }
        guard canControl(machineID: workspace.machineID), self.workspace(id: workspace.id) != nil,
              let client = client(forMachine: workspace.machineID) else {
            throw APIError.invalidResponse
        }
        try await client.unstageGitFile(workspaceID: workspace.workspaceID, file: file)
        toastMessage = "Unstaged \(file)"
    }

    func startCleanup(machineID: String, workspaceIDs: [String]) async throws -> CleanupStartRunResponse {
        if isDemoMode {
            return CleanupStartRunResponse(ok: true, runID: "clr_demo", status: .collecting)
        }
        guard canControl(machineID: machineID),
              workspaceIDs.allSatisfy({ rawID in workspaces.contains { $0.machineID == machineID && $0.workspaceID == rawID } }),
              let client = client(forMachine: machineID) else {
            throw APIError.invalidResponse
        }
        let settings = CleanupSettings.load(from: .standard)
        return try await client.startCleanupRun(
            CleanupStartRunRequest(
                model: settings.model.isEmpty ? nil : settings.model,
                thinkingLevel: settings.thinkingLevel,
                costThresholdUSD: settings.costThresholdUSD,
                tailLines: nil,
                keepEvidence: nil,
                workspaceIDs: workspaceIDs.isEmpty ? nil : workspaceIDs
            )
        )
    }

    func fetchCleanupRun(machineID: String, runID: String) async throws -> CleanupRunEnvelope {
        guard let client = client(forMachine: machineID) else {
            let machineName = machines.first(where: { $0.id == machineID })?.name ?? machineID
            throw APIError.noActiveConnection(machineID: machineName)
        }
        return try await client.fetchCleanupRun(id: runID)
    }

    func applyCleanupRun(
        machineID: String,
        runID: String,
        paneIDs: [String],
        workspaceIDs: [String]
    ) async throws -> CleanupApplyResponse {
        if isDemoMode {
            let response = CleanupApplyResponse(
                applied: CleanupAppliedItems(panes: paneIDs, workspaces: workspaceIDs),
                skipped: []
            )
            toastMessage = "Closed \(paneIDs.count) panes"
            return response
        }
        guard canControl(machineID: machineID), let client = client(forMachine: machineID) else {
            throw APIError.invalidResponse
        }
        let response = try await client.applyCleanupRun(
            id: runID,
            paneIDs: paneIDs,
            workspaceIDs: workspaceIDs
        )
        toastMessage = "Closed \(response.applied.panes.count) panes"
        return response
    }

    func cancelCleanupRun(machineID: String, runID: String) async throws {
        guard !isDemoMode, canControl(machineID: machineID), let client = client(forMachine: machineID) else {
            if isDemoMode { return }
            throw APIError.invalidResponse
        }
        try await client.cancelCleanupRun(id: runID)
    }

    func fetchCleanupModels(machineID: String? = nil) async throws -> CleanupModelCatalog {
        if isDemoMode {
            return CleanupModelCatalog(
                ok: true,
                models: [CleanupAvailableModel(
                    provider: "custom-lux-dspark",
                    modelID: "qwen3.8-27b-nvfp4-dspark",
                    name: "Qwen3.8 27B (dspark)",
                    contextWindow: 122_900
                )],
                defaultModel: CleanupModelDefault(
                    provider: "custom-lux-dspark",
                    modelID: "qwen3.8-27b-nvfp4-dspark",
                    thinkingLevel: .medium
                )
            )
        }
        let client = machineID.flatMap { self.client(forMachine: $0) } ?? primaryClient
        guard let client else { throw APIError.invalidResponse }
        return try await client.fetchCleanupModels()
    }

    func makeCleanupController(for target: CleanupSheetTarget) -> CleanupRunController {
        CleanupRunController(
            isDemoMode: isDemoMode,
            runContext: "machine \(target.machineID), workspace \(target.workspaceID ?? "all")",
            start: { _ in
                try await self.startCleanup(
                    machineID: target.machineID,
                    workspaceIDs: target.workspaceID.map { [$0] } ?? []
                )
            },
            fetch: { runID in
                try await self.fetchCleanupRun(machineID: target.machineID, runID: runID)
            },
            apply: { runID, paneIDs, workspaceIDs in
                try await self.applyCleanupRun(
                    machineID: target.machineID,
                    runID: runID,
                    paneIDs: paneIDs,
                    workspaceIDs: workspaceIDs
                )
            },
            cancel: { runID in
                try await self.cancelCleanupRun(machineID: target.machineID, runID: runID)
            }
        )
    }

    func fetchSkills(for workspace: HerdrWorkspace) async throws -> SkillsResponse {
        if isDemoMode { return DemoData.skills(for: workspace) }
        guard canControl(machineID: workspace.machineID), self.workspace(id: workspace.id) != nil,
              let client = client(forMachine: workspace.machineID) else {
            throw APIError.invalidResponse
        }
        return try await client.fetchSkills(workspaceID: workspace.workspaceID)
    }

    func searchFiles(in workspace: HerdrWorkspace, query: String) async throws -> [ProjectFileMatch] {
        if isDemoMode { return DemoData.fileSearch(query: query, workspace: workspace).files }
        guard canControl(machineID: workspace.machineID), self.workspace(id: workspace.id) != nil,
              let client = client(forMachine: workspace.machineID) else {
            throw APIError.invalidResponse
        }
        return try await client.searchFiles(workspaceID: workspace.workspaceID, query: query).files
    }

    func fetchAssignedJiraTickets() async throws -> [JiraTicket] {
        if isDemoMode { return DemoData.jiraTickets.tickets }
        guard canControl, let client = primaryClient else { throw APIError.invalidResponse }
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
        guard canControl, let client = primaryClient else { throw APIError.invalidResponse }
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
                workspaceID: workspace.workspaceID,
                createdAt: ISO8601DateFormatter().string(from: .now)
            )
        }
        guard canControl(machineID: workspace.machineID), self.workspace(id: workspace.id) != nil,
              let client = client(forMachine: workspace.machineID) else {
            throw APIError.invalidResponse
        }
        let response = try await client.uploadAttachment(
            workspaceID: workspace.workspaceID,
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

        let privateClient = preferPrivateTranscription && canControl ? primaryClient : nil
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
        guard !isDemoMode, canControl(machineID: pane.machineID), self.pane(id: pane.id) != nil,
              let client = client(forMachine: pane.machineID) else { return nil }
        return await client.terminalEvents(paneID: pane.paneID)
    }

    func fetchPiConversationSnapshot(for pane: HerdrPane) async throws -> PiConversationSnapshot {
        guard !isDemoMode, canControl(machineID: pane.machineID), self.pane(id: pane.id) != nil,
              let client = client(forMachine: pane.machineID) else {
            throw APIError.invalidResponse
        }
        return try await client.fetchPiConversationSnapshot(paneID: pane.paneID)
    }

    func piConversationEvents(
        for pane: HerdrPane,
        after cursor: String?
    ) async -> AsyncThrowingStream<PiConversationStreamEvent, any Error>? {
        guard !isDemoMode, canControl(machineID: pane.machineID), self.pane(id: pane.id) != nil,
              let client = client(forMachine: pane.machineID) else { return nil }
        return await client.piConversationEvents(paneID: pane.paneID, after: cursor)
    }

    func sendPiConversationPrompt(
        _ text: String,
        disposition: PiPromptDisposition,
        to pane: HerdrPane
    ) async throws {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty,
              !isDemoMode,
              canControl(machineID: pane.machineID),
              self.pane(id: pane.id) != nil,
              let client = client(forMachine: pane.machineID)
        else { throw APIError.invalidResponse }
        try await client.sendPiPrompt(paneID: pane.paneID, text: prompt, disposition: disposition)
    }

    func abortPiConversation(for pane: HerdrPane) async throws {
        guard !isDemoMode, canControl(machineID: pane.machineID), self.pane(id: pane.id) != nil,
              let client = client(forMachine: pane.machineID) else {
            throw APIError.invalidResponse
        }
        try await client.abortPiConversation(paneID: pane.paneID)
    }

    func respondToPiInteraction(
        id: String,
        response: PiInteractionResponseBody,
        in pane: HerdrPane
    ) async throws {
        guard !isDemoMode, canControl(machineID: pane.machineID), self.pane(id: pane.id) != nil,
              let client = client(forMachine: pane.machineID) else {
            throw APIError.invalidResponse
        }
        try await client.respondToPiInteraction(
            paneID: pane.paneID,
            interactionID: id,
            response: response
        )
    }

    func fetchPiModels(for pane: HerdrPane) async throws -> PiModelCatalogResponse {
        guard !isDemoMode, canControl(machineID: pane.machineID), self.pane(id: pane.id) != nil,
              let client = client(forMachine: pane.machineID) else {
            throw APIError.invalidResponse
        }
        return try await client.fetchPiModels(paneID: pane.paneID)
    }

    func setPiModel(provider: String, modelID: String, for pane: HerdrPane) async throws {
        guard !isDemoMode, canControl(machineID: pane.machineID), self.pane(id: pane.id) != nil,
              let client = client(forMachine: pane.machineID) else {
            throw APIError.invalidResponse
        }
        try await client.setPiModel(paneID: pane.paneID, provider: provider, modelID: modelID)
    }

    func setPiThinkingLevel(level: String, for pane: HerdrPane) async throws -> String? {
        guard !isDemoMode, canControl(machineID: pane.machineID), self.pane(id: pane.id) != nil,
              let client = client(forMachine: pane.machineID) else {
            throw APIError.invalidResponse
        }
        return try await client.setPiThinkingLevel(paneID: pane.paneID, level: level)
    }

    func sendPrompt(_ text: String, to pane: HerdrPane) async -> Bool {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return false }
        if isDemoMode {
            toastMessage = "Sent to \(pane.displayAgentName)"
            return true
        }
        guard !isSending, canControl(machineID: pane.machineID), self.pane(id: pane.id) != nil,
              let client = client(forMachine: pane.machineID) else { return false }
        isSending = true
        defer { isSending = false }
        do {
            if pane.agentStatus == .unknown {
                try await client.sendText(toPane: pane.paneID, text: prompt, submit: true)
            } else {
                try await client.promptPane(id: pane.paneID, text: prompt)
            }
            toastMessage = "Sent to \(pane.displayAgentName)"
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func sendKeys(_ keys: [String], to pane: HerdrPane) async -> Bool {
        if isDemoMode {
            toastMessage = keys.joined(separator: " + ").uppercased()
            return true
        }
        guard canControl(machineID: pane.machineID), self.pane(id: pane.id) != nil,
              let client = client(forMachine: pane.machineID) else { return false }
        do {
            try await client.sendKeys(toPane: pane.paneID, keys: keys)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func sendText(_ text: String, to pane: HerdrPane) async -> Bool {
        if isDemoMode {
            toastMessage = "Sent to \(pane.displayAgentName)"
            return true
        }
        guard canControl(machineID: pane.machineID), self.pane(id: pane.id) != nil,
              let client = client(forMachine: pane.machineID) else { return false }
        do {
            try await client.sendText(toPane: pane.paneID, text: text, submit: false)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func startNewPiChat(in pane: HerdrPane) async {
        if isDemoMode {
            toastMessage = "started a new pi chat"
            return
        }
        guard canControl(machineID: pane.machineID), self.pane(id: pane.id) != nil,
              let client = client(forMachine: pane.machineID) else { return }
        do {
            try await client.sendText(toPane: pane.paneID, text: "/new", submit: false)
            try await client.sendKeys(toPane: pane.paneID, keys: ["enter"])
            toastMessage = "started a new pi chat"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func endPiSession(in pane: HerdrPane) async {
        if isDemoMode {
            toastMessage = "ended the pi session"
            return
        }
        guard canControl(machineID: pane.machineID), self.pane(id: pane.id) != nil,
              let client = client(forMachine: pane.machineID) else { return }
        do {
            try await client.sendText(toPane: pane.paneID, text: "/quit", submit: false)
            try await client.sendKeys(toPane: pane.paneID, keys: ["enter"])
            toastMessage = "ended the pi session"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func split(_ pane: HerdrPane, direction: String) async -> String? {
        var newPaneID: String?
        await perform("Pane split", machineID: pane.machineID) { client in
            newPaneID = try await client.splitPane(id: pane.paneID, direction: direction)
        }
        return newPaneID
    }

    func addPane(toTab tab: HerdrTab, in workspace: HerdrWorkspace, running command: String? = nil) async {
        if isDemoMode {
            toastMessage = command == nil ? "added a shell" : "started a new pi chat"
            return
        }
        guard canControl(machineID: workspace.machineID),
              let client = client(forMachine: workspace.machineID),
              let source = workspace.panes
                .filter({ $0.scopedTabID == tab.id })
                .sorted(by: { $0.paneID < $1.paneID })
                .last
        else { return }
        do {
            let newPaneID = try await client.splitPane(id: source.paneID, direction: "right")
            if let command, let newPaneID {
                try await client.sendText(toPane: newPaneID, text: command, submit: true)
            }
            try await refresh(
                machineID: workspace.machineID,
                using: client,
                showSpinner: false,
                expectedGeneration: connectionGeneration
            )
            toastMessage = command == nil ? "added a shell" : "started a new pi chat"
            if command != nil && newPaneID == nil { toastMessage = "pane added — start pi manually" }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func focus(_ pane: HerdrPane) async {
        await perform("Focused on Mac", machineID: pane.machineID) { client in
            try await client.focusPane(id: pane.paneID)
        }
    }

    func focusAndZoom(_ pane: HerdrPane) async {
        await perform("Focused + zoomed on Mac", machineID: pane.machineID) { client in
            try await client.focusPane(id: pane.paneID)
            try await client.zoomPane(id: pane.paneID, mode: "on")
        }
    }

    func close(_ pane: HerdrPane) async {
        await perform("Pane closed", machineID: pane.machineID) { client in
            try await client.closePane(id: pane.paneID)
        }
    }

    func rename(_ pane: HerdrPane, label: String) async {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await perform("Pane renamed", machineID: pane.machineID) { client in
            try await client.renamePane(id: pane.paneID, label: trimmed)
        }
    }

    func focus(_ workspace: HerdrWorkspace) async {
        await perform("Workspace focused on Mac", machineID: workspace.machineID) { client in
            try await client.focusWorkspace(id: workspace.workspaceID)
        }
    }

    func rename(_ workspace: HerdrWorkspace, label: String) async {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await perform("Workspace renamed", machineID: workspace.machineID) { client in
            try await client.renameWorkspace(id: workspace.workspaceID, label: trimmed)
        }
    }

    func close(_ workspace: HerdrWorkspace) async {
        await perform("Workspace closed", machineID: workspace.machineID) { client in
            try await client.closeWorkspace(id: workspace.workspaceID)
        }
    }

    func startAgent(in pane: HerdrPane, kind: String) async {
        let normalizedKind = kind.lowercased()
        let suffix = pane.paneID.replacing(":", with: "-")
        await perform("\(kind.capitalized) started", machineID: pane.machineID) { client in
            try await client.startAgent(
                inPane: pane.paneID,
                name: "mobile-\(suffix)",
                kind: normalizedKind
            )
        }
    }

    func createWorkspace(label: String, cwd: String, machineID: String? = nil) async -> Bool {
        var succeeded = false
        await perform("Workspace created", machineID: machineID ?? machines.first?.id) { client in
            try await client.createWorkspace(label: label, cwd: cwd)
            succeeded = true
        }
        return succeeded
    }

    func createQuickPiSession(machineID: String? = nil) async {
        if isDemoMode {
            toastMessage = "quick pi sessions need a live connection"
            return
        }
        let label = Date.now.formatted(.dateTime.month(.abbreviated).day().hour().minute()).lowercased()
        var spawnedPaneID: String?
        await perform("pi session spawning", machineID: machineID ?? machines.first?.id) { client in
            let response = try await client.createQuickPiSession(label: label)
            spawnedPaneID = response.paneID
        }
        if let spawnedPaneID {
            openPane(id: spawnedPaneID)
        }
    }

    func createTab(in workspace: HerdrWorkspace) async {
        await perform("Tab created", machineID: workspace.machineID) { client in
            try await client.createTab(
                workspaceID: workspace.workspaceID,
                label: "Tab \(workspace.tabCount + 1)"
            )
        }
    }

    func markAlertRead(_ alert: HerdrAlert) async {
        if isDemoMode {
            alerts = alerts.map { item in
                guard item.id == alert.id else { return item }
                return HerdrAlert(
                    id: item.rawID,
                    workspaceID: item.workspaceID,
                    paneID: item.paneID,
                    status: item.status,
                    title: item.title,
                    message: item.message,
                    createdAt: item.createdAt,
                    isRead: true
                ).stamped(machineID: item.machineID)
            }
            updateBadgeIfNeeded()
            return
        }
        guard let client = client(forMachine: alert.machineID) else { return }
        do {
            try await client.markAlertRead(id: alert.rawID)
            try await refresh(
                machineID: alert.machineID,
                using: client,
                showSpinner: false,
                expectedGeneration: connectionGeneration
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func markAllAlertsRead() async {
        if isDemoMode {
            alerts = alerts.map { item in
                HerdrAlert(
                    id: item.rawID,
                    workspaceID: item.workspaceID,
                    paneID: item.paneID,
                    status: item.status,
                    title: item.title,
                    message: item.message,
                    createdAt: item.createdAt,
                    isRead: true
                ).stamped(machineID: item.machineID)
            }
            updateBadgeIfNeeded()
            return
        }
        for machine in machines {
            guard let client = client(forMachine: machine.id) else { continue }
            do {
                try await client.markAllAlertsRead()
                try await refresh(machineID: machine.id, using: client, showSpinner: false, expectedGeneration: connectionGeneration)
            } catch {
                errorMessage = error.localizedDescription
            }
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
        for machine in machines where runtimes[machine.id]?.state == .live {
            guard let client = client(forMachine: machine.id) else { continue }
            await syncPushDevice(machineID: machine.id, using: client, expectedGeneration: connectionGeneration)
        }
    }

    func openPane(id paneID: String) {
        guard !paneID.isEmpty else { return }
        guard let pane = pane(id: paneID) ?? resolveRawPane(id: paneID) else {
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
        userDefaults.set(
            Array(collapsedSidebarWorkspaceIDs),
            forKey: "herdr.sidebar.collapsedWorkspaces"
        )
    }

    func toggleSidebarTabSection(_ tabID: String) {
        if collapsedSidebarTabIDs.contains(tabID) {
            collapsedSidebarTabIDs.remove(tabID)
        } else {
            collapsedSidebarTabIDs.insert(tabID)
        }
        userDefaults.set(
            Array(collapsedSidebarTabIDs),
            forKey: "herdr.sidebar.collapsedTabs"
        )
    }

    func toggleSidebarMachineSection(_ machineID: String) {
        if collapsedSidebarMachineIDs.contains(machineID) {
            collapsedSidebarMachineIDs.remove(machineID)
        } else {
            collapsedSidebarMachineIDs.insert(machineID)
        }
        userDefaults.set(
            Array(collapsedSidebarMachineIDs),
            forKey: "herdr.sidebar.collapsedMachines"
        )
    }

    func toggleStarredChat(_ paneID: String) {
        if starredChatIDs.contains(paneID) {
            starredChatIDs.remove(paneID)
        } else {
            starredChatIDs.insert(paneID)
        }
        userDefaults.set(Array(starredChatIDs), forKey: "herdr.sidebar.starredChats")
        guard !isDemoMode, let pane = pane(id: paneID), canControl(machineID: pane.machineID),
              let client = client(forMachine: pane.machineID) else { return }
        let starred = starredChatIDs.contains(paneID)
        let rawID = pane.paneID
        Task { try? await client.setPaneStar(id: rawID, starred: starred) }
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
        if let paneID = Self.paneID(from: url) {
            openPane(id: paneID)
        }
    }

    /// Resolves a pane ID from `herdr://pane/{id}` custom-scheme links and
    /// `https://{host}/open/pane/{id}` universal links, plus the
    /// `?pane=`/`?paneId=`/`?pane_id=` query forms of either.
    nonisolated static func paneID(from url: URL) -> String? {
        let scheme = url.scheme?.lowercased()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryPaneID = components?.queryItems?.first {
            $0.name == "pane" || $0.name == "paneId" || $0.name == "pane_id"
        }?.value
        switch scheme {
        case "herdr":
            let pathPaneID = url.host?.lowercased() == "pane"
                ? url.pathComponents.dropFirst().first?.removingPercentEncoding
                : nil
            return queryPaneID?.nonEmpty ?? pathPaneID?.nonEmpty
        case "https", "http":
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.count >= 2,
                  parts[0].lowercased() == "open",
                  parts[1].lowercased() == "pane" else { return nil }
            if parts.count >= 3 {
                return parts[2].nonEmpty
            }
            return queryPaneID?.nonEmpty
        default:
            return nil
        }
    }

    func refresh(
        machineID: String,
        using client: HerdrAPIClient,
        showSpinner: Bool = true,
        expectedGeneration: Int
    ) async throws {
        HerdrPerfDiagnostics.checkpoint("fleet.refresh")
        if showSpinner { isRefreshing = true }
        defer {
            if showSpinner, expectedGeneration == connectionGeneration { isRefreshing = false }
        }
        let response = try await client.fetchWorkspaces()
        guard expectedGeneration == connectionGeneration else { throw CancellationError() }
        let previousAlerts = alerts.filter { $0.machineID == machineID }
        let previousAlertIDs = Set(previousAlerts.map(\.id))
        let previousReadAlertIDs = Set(previousAlerts.filter(\.isRead).map(\.id))
        let freshWorkspaces = response.workspaces.map { $0.stamped(machineID: machineID) }
        let freshAlerts = response.alerts.map { $0.stamped(machineID: machineID) }
        let mergedWorkspaces = workspaces.filter { $0.machineID != machineID } + freshWorkspaces
        let mergedAlerts = alerts.filter { $0.machineID != machineID } + freshAlerts
        if mergedWorkspaces != workspaces { workspaces = mergedWorkspaces }
        if mergedAlerts != alerts { alerts = mergedAlerts }
        reconcileStarredChats(machineID: machineID, serverStarredRawIDs: response.starredPaneIDs)
        let currentAlertIDs = Set(freshAlerts.map(\.id))
        let readAlertIDs = Set(freshAlerts.filter(\.isRead).map(\.id))
        let removedAlertIDs = previousAlertIDs.subtracting(currentAlertIDs)
        let staleAlertIDs = readAlertIDs.subtracting(previousReadAlertIDs).union(removedAlertIDs)
        let shouldSweepDelivered = !(runtimes[machineID]?.didSweepDelivered ?? false)
        if shouldSweepDelivered {
            var runtime = runtimes[machineID] ?? MachineRuntime()
            runtime.didSweepDelivered = true
            runtimes[machineID] = runtime
        }
        let deliveredAlertIDs = shouldSweepDelivered
            ? staleAlertIDs.union(readAlertIDs)
            : staleAlertIDs
        if !deliveredAlertIDs.isEmpty {
            Task { await NotificationManager.removeDelivered(alertIDs: deliveredAlertIDs) }
        }
        lastUpdated = .now
        if errorMessage != nil { errorMessage = nil }
        if lastPresentedConnectionError != nil { lastPresentedConnectionError = nil }

        repairNavigation(machineID: machineID, freshWorkspaces: freshWorkspaces)
        resolvePendingPaneRoute()

        if smartAlertsEnabled && !remotePushConfigured {
            for alert in freshAlerts where !alert.isRead && !previousAlertIDs.contains(alert.id) {
                await NotificationManager.post(alert)
            }
        }
        for alert in freshAlerts where !alert.isRead && pendingLocalAlertIDs.contains(alert.id) {
            await NotificationManager.post(alert)
            pendingLocalAlertIDs.remove(alert.id)
        }
        updateBadgeIfNeeded()
    }

    private func updateBadgeIfNeeded() {
        let count = unreadAlertCount
        guard count != lastBadgeCount else { return }
        lastBadgeCount = count
        Task { await NotificationManager.setBadge(count) }
    }

    private func syncPushDevice(machineID: String, using client: HerdrAPIClient, expectedGeneration: Int) async {
        guard let token = pendingPushToken,
              runtimes[machineID]?.connection?.generation == expectedGeneration,
              runtimes[machineID]?.connection?.configuration.token.isEmpty == false
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
        machineID: String?,
        operation: (HerdrAPIClient) async throws -> Void
    ) async {
        if isDemoMode {
            toastMessage = successMessage
            return
        }
        guard let machineID, canControl(machineID: machineID), let client = client(forMachine: machineID) else {
            toastMessage = "Reconnect before controlling Herdr"
            return
        }
        let generation = connectionGeneration
        do {
            try await operation(client)
            guard generation == connectionGeneration else { return }
            toastMessage = successMessage
            try await refresh(
                machineID: machineID,
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
        "pi.session_compact",
    ]

    private func matchesSearch(_ workspace: HerdrWorkspace) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return workspace.label.localizedStandardContains(query)
            || workspace.displayPath.localizedStandardContains(query)
            || workspace.panes.contains { $0.displayTitle.localizedStandardContains(query) }
    }

    private func loadDemo() {
        machines = [
            HerdrMachine(id: "demo1", name: "rocketbot", urlString: ""),
            HerdrMachine(id: "demo2", name: "work mbp", urlString: ""),
        ]
        if case let .machine(id) = machineScope, !machines.contains(where: { $0.id == id }) {
            setMachineScope(.all)
        }
        workspaces = DemoData.workspaces.map { $0.stamped(machineID: "demo1") }
            + DemoData.workspacesForWorkMBP.map { $0.stamped(machineID: "demo2") }
        alerts = DemoData.alerts.map { $0.stamped(machineID: "demo1") }
        runtimes = Dictionary(uniqueKeysWithValues: machines.map {
            ($0.id, MachineRuntime(state: .demo))
        })
        machineStates = Dictionary(uniqueKeysWithValues: machines.map { ($0.id, ConnectionState.demo) })
        let demoStars = starredChatIDs.filter {
            guard let scope = MachineScopedID.split($0) else { return false }
            return scope.machineID == "demo1" || scope.machineID == "demo2"
        }
        if demoStars.isEmpty {
            starredChatIDs.formUnion(["demo1|w1:p1", "demo2|w1:p1"])
            userDefaults.set(Array(starredChatIDs), forKey: "herdr.sidebar.starredChats")
        }
        selectedWorkspaceID = selectedWorkspaceID ?? workspaces.first?.id
        connectionState = .demo
        lastUpdated = .now
    }

    private func resetConnectionState() {
        cancelDeferredRefreshes()
        runtimes = [:]
        machineStates = [:]
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
        lastBadgeCount = nil
    }

    private func repairNavigation(machineID: String, freshWorkspaces: [HerdrWorkspace]) {
        let validWorkspaceIDs = Set(freshWorkspaces.map(\.id))
        let validTabIDs = Set(freshWorkspaces.flatMap(\.tabs).map(\.id))
        let validPaneIDs = Set(freshWorkspaces.flatMap(\.panes).map(\.id))
        let repairedPath = workspacePath.filter { route in
            switch route {
            case let .workspace(id):
                guard MachineScopedID.split(id)?.machineID == machineID else { return true }
                return validWorkspaceIDs.contains(id)
            case let .pane(id):
                guard MachineScopedID.split(id)?.machineID == machineID else { return true }
                return validPaneIDs.contains(id)
            }
        }
        if repairedPath != workspacePath { workspacePath = repairedPath }
        if let selectedWorkspaceID,
           MachineScopedID.split(selectedWorkspaceID)?.machineID == machineID,
           !validWorkspaceIDs.contains(selectedWorkspaceID) {
            self.selectedWorkspaceID = workspaces.first?.id
        }
        if let selectedPaneID,
           MachineScopedID.split(selectedPaneID)?.machineID == machineID,
           !validPaneIDs.contains(selectedPaneID) {
            self.selectedPaneID = nil
        }
        let untouchedCollapsed = collapsedSidebarWorkspaceIDs.filter {
            MachineScopedID.split($0)?.machineID != machineID
        }
        let prunedCollapsed = untouchedCollapsed.union(collapsedSidebarWorkspaceIDs
            .filter { MachineScopedID.split($0)?.machineID == machineID && validWorkspaceIDs.contains($0) })
        if prunedCollapsed != collapsedSidebarWorkspaceIDs {
            collapsedSidebarWorkspaceIDs = prunedCollapsed
            userDefaults.set(Array(collapsedSidebarWorkspaceIDs), forKey: "herdr.sidebar.collapsedWorkspaces")
        }
        let untouchedCollapsedTabs = collapsedSidebarTabIDs.filter {
            MachineScopedID.split($0)?.machineID != machineID
        }
        let prunedCollapsedTabs = untouchedCollapsedTabs.union(collapsedSidebarTabIDs
            .filter { MachineScopedID.split($0)?.machineID == machineID && validTabIDs.contains($0) })
        if prunedCollapsedTabs != collapsedSidebarTabIDs {
            collapsedSidebarTabIDs = prunedCollapsedTabs
            userDefaults.set(Array(collapsedSidebarTabIDs), forKey: "herdr.sidebar.collapsedTabs")
        }
    }

    private func resolvePendingPaneRoute() {
        guard let pendingPaneID, let pane = resolveRawPane(id: pendingPaneID) else { return }
        self.pendingPaneID = nil
        route(to: pane)
    }

    private func route(to pane: HerdrPane) {
        isSidebarPresented = false
        selectedTab = .workspaces
        selectedWorkspaceID = workspace(containing: pane)?.id
        selectedPaneID = pane.id
        workspacePath = selectedWorkspaceID.map { [.workspace($0), .pane(pane.id)] } ?? [.pane(pane.id)]
    }

    private func handlePushDelivery(_ event: HerdrEvent, machineID: String) async {
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
        let scopedID = MachineScopedID.compose(machineID: machineID, rawID: alertID)
        if let alert = alerts.first(where: { $0.machineID == machineID && $0.rawID == alertID && !$0.isRead }) {
            await NotificationManager.post(alert)
        } else {
            pendingLocalAlertIDs.insert(scopedID)
        }
    }

    nonisolated static func aggregateConnectionState(
        machineStates: [ConnectionState],
        isDemoMode: Bool,
        hasMachines: Bool
    ) -> ConnectionState {
        if isDemoMode { return .demo }
        if !hasMachines { return .disconnected }
        if machineStates.contains(.live) { return .live }
        if machineStates.contains(.connecting) { return .connecting }
        return .failed
    }

    func reconcileStarredChats(machineID: String, serverStarredRawIDs: [String]?) {
        guard let serverStarredRawIDs else { return }
        let otherMachines = starredChatIDs.filter { MachineScopedID.split($0)?.machineID != machineID }
        let scoped = Set(serverStarredRawIDs.map { MachineScopedID.compose(machineID: machineID, rawID: $0) })
        let merged = otherMachines.union(scoped)
        guard merged != starredChatIDs else { return }
        starredChatIDs = merged
        userDefaults.set(Array(merged), forKey: "herdr.sidebar.starredChats")
    }

    func removeMachine(id: String) {
        runtimes[id]?.deferredRefreshTask?.cancel()
        machines.removeAll { $0.id == id }
        if !isDemoMode {
            persistMachines()
            KeychainStore.removeValue(for: "api-token.\(id)")
        }
        runtimes[id] = nil
        machineStates[id] = nil
        workspaces.removeAll { $0.machineID == id }
        alerts.removeAll { $0.machineID == id }
        starredChatIDs = starredChatIDs.filter { MachineScopedID.split($0)?.machineID != id }
        collapsedSidebarWorkspaceIDs = collapsedSidebarWorkspaceIDs.filter { MachineScopedID.split($0)?.machineID != id }
        collapsedSidebarTabIDs = collapsedSidebarTabIDs.filter { MachineScopedID.split($0)?.machineID != id }
        collapsedSidebarMachineIDs.remove(id)
        userDefaults.set(Array(starredChatIDs), forKey: "herdr.sidebar.starredChats")
        userDefaults.set(Array(collapsedSidebarWorkspaceIDs), forKey: "herdr.sidebar.collapsedWorkspaces")
        userDefaults.set(Array(collapsedSidebarTabIDs), forKey: "herdr.sidebar.collapsedTabs")
        userDefaults.set(Array(collapsedSidebarMachineIDs), forKey: "herdr.sidebar.collapsedMachines")
        if case let .machine(scopeID) = machineScope, scopeID == id {
            machineScope = .all
            machineScope.save(to: userDefaults)
        }
        connectionGeneration += 1
        updateAggregateConnectionState()
        mirrorPrimaryConnection()
    }

    private var primaryClient: HerdrAPIClient? {
        machines.first.flatMap { runtimes[$0.id]?.client }
    }

    private func client(forMachine id: String) -> HerdrAPIClient? {
        runtimes[id]?.client
    }

    /// Internal setup seam used by deterministic URLProtocol-backed tests.
    func prepareRuntime(for machine: HerdrMachine, generation: Int) {
        runtimes[machine.id]?.deferredRefreshTask?.cancel()
        let token = KeychainStore.value(for: "api-token.\(machine.id)")
        guard let configuration = ServerConfiguration(urlString: machine.urlString, token: token) else { return }
        runtimes[machine.id] = MachineRuntime(
            client: clientFactory(configuration),
            connection: ActiveServerConnection(configuration: configuration, generation: generation),
            state: .connecting
        )
        machineStates[machine.id] = .connecting
        mirrorPrimaryConnection()
    }

    private func runMachineConnection(machine: HerdrMachine, expectedGeneration: Int) async {
        var retryDelay = 2.0
        while !Task.isCancelled && expectedGeneration == connectionGeneration {
            guard let client = client(forMachine: machine.id) else { return }
            do {
                try await refresh(machineID: machine.id, using: client, expectedGeneration: expectedGeneration)
                noteRefreshCompleted(for: machine.id)
                guard expectedGeneration == connectionGeneration else { return }
                setRuntimeState(.live, for: machine.id)
                await syncPushDevice(machineID: machine.id, using: client, expectedGeneration: expectedGeneration)
                retryDelay = 2
                for try await event in await client.events(after: runtimes[machine.id]?.lastEventID) {
                    try Task.checkCancellation()
                    guard expectedGeneration == connectionGeneration else { return }
                    if event.event == "ready" { seedLastEventIDFromReady(event, for: machine.id) }
                    recordLastEventID(event.id, for: machine.id)
                    if event.event == "stream.reset", streamResetIsBackendRestart(event) {
                        resetLastEventID(for: machine.id)
                    }
                    if event.event == "snapshot.updated" || event.event == "alert.created" ||
                        event.event == "alert.updated" || event.event == "alerts.read_state_changed" ||
                        event.event == "stars.changed" || event.event == "stream.reset" ||
                        Self.piCapabilityEvents.contains(event.event) {
                        if !shouldSkipSyntheticConnectRefresh(event, machineID: machine.id) {
                            noteFleetRefreshNeeded(
                                machineID: machine.id,
                                client: client,
                                expectedGeneration: expectedGeneration
                            )
                        }
                    } else if event.event == "push.delivery" {
                        await handlePushDelivery(event, machineID: machine.id)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard expectedGeneration == connectionGeneration else { return }
                handleRefreshFailure(error, machineID: machine.id, expectedGeneration: expectedGeneration)
                do { try await Task.sleep(for: .seconds(retryDelay)) } catch { return }
                retryDelay = min(retryDelay * 2, 15)
            }
        }
    }

    private func recordLastEventID(_ eventID: Int?, for machineID: String) {
        guard let eventID else { return }
        var runtime = runtimes[machineID] ?? MachineRuntime()
        runtime.lastEventID = eventID
        runtimes[machineID] = runtime
    }

    private func resetLastEventID(for machineID: String) {
        var runtime = runtimes[machineID] ?? MachineRuntime()
        runtime.lastEventID = nil
        runtimes[machineID] = runtime
    }

    private func streamResetIsBackendRestart(_ event: HerdrEvent) -> Bool {
        guard case let .object(values)? = event.data,
              case let .string(reason)? = values["reason"] else { return false }
        return reason == "backend_restarted"
    }

    private func noteRefreshCompleted(for machineID: String) {
        var runtime = runtimes[machineID] ?? MachineRuntime()
        runtime.lastRefreshCompletedAt = ContinuousClock().now
        runtimes[machineID] = runtime
    }

    private func seedLastEventIDFromReady(_ event: HerdrEvent, for machineID: String) {
        guard runtimes[machineID]?.lastEventID == nil,
              case let .object(values)? = event.data,
              case let .number(lastEventID)? = values["lastEventId"]
        else { return }
        recordLastEventID(Int(lastEventID), for: machineID)
    }

    private func shouldSkipSyntheticConnectRefresh(_ event: HerdrEvent, machineID: String) -> Bool {
        guard event.event == "snapshot.updated",
              case let .object(values)? = event.data,
              case let .bool(true)? = values["synthetic"],
              let completed = runtimes[machineID]?.lastRefreshCompletedAt
        else { return false }
        return completed.duration(to: ContinuousClock().now) < .seconds(2)
    }

    /// Exposed at internal visibility for deterministic tests.
    func noteFleetRefreshNeeded(
        machineID: String,
        client: HerdrAPIClient,
        expectedGeneration: Int
    ) {
        var runtime = runtimes[machineID] ?? MachineRuntime()
        runtime.pendingRefresh = true
        guard runtime.deferredRefreshTask == nil else {
            runtimes[machineID] = runtime
            return
        }
        runtime.deferredRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.clearDeferredRefreshTask(machineID: machineID, expectedGeneration: expectedGeneration) }
            let clock = ContinuousClock()
            var retryBackoff = self.fleetRefreshRetryBase
            while !Task.isCancelled, expectedGeneration == self.connectionGeneration {
                if let completed = self.runtimes[machineID]?.lastRefreshCompletedAt {
                    do { try await clock.sleep(until: completed.advanced(by: Self.fleetRefreshWindow)) }
                    catch { return }
                }
                guard !Task.isCancelled, expectedGeneration == self.connectionGeneration else { return }
                var current = self.runtimes[machineID] ?? MachineRuntime()
                guard current.pendingRefresh else {
                    current.deferredRefreshTask = nil
                    self.runtimes[machineID] = current
                    return
                }
                current.pendingRefresh = false
                self.runtimes[machineID] = current
                do {
                    try await self.refresh(machineID: machineID, using: client, showSpinner: false, expectedGeneration: expectedGeneration)
                    self.noteRefreshCompleted(for: machineID)
                    self.setRuntimeState(.live, for: machineID)
                    retryBackoff = self.fleetRefreshRetryBase
                } catch is CancellationError {
                    return
                } catch {
                    self.handleRefreshFailure(error, machineID: machineID, expectedGeneration: expectedGeneration)
                    var failed = self.runtimes[machineID] ?? MachineRuntime()
                    failed.pendingRefresh = true
                    self.runtimes[machineID] = failed
                    do { try await clock.sleep(for: retryBackoff) } catch { return }
                    retryBackoff = min(retryBackoff * 2, .seconds(15))
                }
            }
        }
        runtimes[machineID] = runtime
    }

    private func handleRefreshFailure(_ error: Error, machineID: String, expectedGeneration: Int) {
        guard expectedGeneration == connectionGeneration else { return }
        let failed = noteConnectionFailure(machineID: machineID, now: .now)
        setRuntimeState(failed ? .failed : .connecting, for: machineID, error: error.localizedDescription)
        if connectionState == .failed, lastPresentedConnectionError != error.localizedDescription {
            lastPresentedConnectionError = error.localizedDescription
            errorMessage = error.localizedDescription
        }
    }

    private func clearDeferredRefreshTask(machineID: String, expectedGeneration: Int) {
        guard expectedGeneration == connectionGeneration else { return }
        var runtime = runtimes[machineID] ?? MachineRuntime()
        runtime.deferredRefreshTask = nil
        runtimes[machineID] = runtime
    }

    private func cancelDeferredRefreshes() {
        for runtime in runtimes.values { runtime.deferredRefreshTask?.cancel() }
    }

    private func setRuntimeState(_ state: ConnectionState, for machineID: String, error: String? = nil) {
        var runtime = runtimes[machineID] ?? MachineRuntime()
        runtime.state = state
        runtime.lastError = error
        if state == .live {
            runtime.firstFailureAt = nil
            runtime.lastUpdated = .now
        }
        runtimes[machineID] = runtime
        machineStates[machineID] = state
        updateAggregateConnectionState()
        mirrorPrimaryConnection()
    }

    private func updateAggregateConnectionState() {
        connectionState = Self.aggregateConnectionState(
            machineStates: machines.map { self.machineStates[$0.id] ?? .disconnected },
            isDemoMode: isDemoMode,
            hasMachines: !machines.isEmpty
        )
    }

    private func mirrorPrimaryConnection() {
        activeServerConnection = machines.first.flatMap { runtimes[$0.id]?.connection }
    }

    private func leaveDemoForMachineManagementIfNeeded() {
        guard isDemoMode else { return }
        machines = Self.loadMachines(defaults: userDefaults)
        isDemoMode = false
        hasCompletedSetup = true
        UserDefaults.standard.set(false, forKey: "herdr.demoMode")
        UserDefaults.standard.set(true, forKey: "herdr.completedSetup")
        resetConnectionState()
    }

    private func autoNameFromNetwork(machineID: String, expectedName: String, generation: Int) async {
        guard let client = client(forMachine: machineID) else { return }
        guard let network = try? await client.fetchNetworkInfo(), generation == connectionGeneration,
              let index = machines.firstIndex(where: { $0.id == machineID }),
              machines[index].name == expectedName
        else { return }
        let name = Self.networkMachineName(dnsName: network.tailscaleDNSName, hostname: network.hostname)
        guard !name.isEmpty else { return }
        machines[index].name = name
        persistMachines()
    }

    private func resolveRawPane(id rawID: String) -> HerdrPane? {
        let matches = workspaces.flatMap(\.panes).filter { $0.paneID == rawID }
        guard matches.count > 1 else { return matches.first }
        if let alert = alerts.filter({ $0.paneID == rawID }).max(by: { $0.createdAt < $1.createdAt }),
           let pane = matches.first(where: { $0.machineID == alert.machineID }) {
            return pane
        }
        for machine in machines {
            if let pane = matches.first(where: { $0.machineID == machine.id }) { return pane }
        }
        return matches.first
    }

    private func persistMachines() {
        userDefaults.set(try? JSONEncoder().encode(machines), forKey: "herdr.machines")
    }

    private static func loadMachines(defaults: UserDefaults) -> [HerdrMachine] {
        guard let data = defaults.data(forKey: "herdr.machines"),
              let machines = try? JSONDecoder().decode([HerdrMachine].self, from: data) else { return [] }
        return machines
    }

    private static func migrateMachinesIfNeeded(defaults: UserDefaults) {
        guard defaults.object(forKey: "herdr.machines") == nil else { return }
        guard let urlString = defaults.string(forKey: "herdr.serverURL") else {
            defaults.set(try? JSONEncoder().encode([HerdrMachine]()), forKey: "herdr.machines")
            return
        }
        let machine = HerdrMachine(id: UUID().uuidString, name: Self.machineName(for: urlString), urlString: urlString)
        KeychainStore.set(KeychainStore.value(for: "api-token"), for: "api-token.\(machine.id)")
        for key in ["herdr.sidebar.starredChats", "herdr.sidebar.collapsedWorkspaces"] {
            let values = defaults.stringArray(forKey: key) ?? []
            defaults.set(values.map { MachineScopedID.compose(machineID: machine.id, rawID: $0) }, forKey: key)
        }
        defaults.set(try? JSONEncoder().encode([machine]), forKey: "herdr.machines")
    }

    private static func machineName(for urlString: String) -> String {
        guard let host = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines))?.host else {
            return "my mac"
        }
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if ["localhost", "127.0.0.1", "::1"].contains(normalized) { return "my mac" }
        return host.split(separator: ".").first.map(String.init) ?? "my mac"
    }

    private static func networkMachineName(dnsName: String, hostname: String) -> String {
        let candidate = dnsName.nonEmpty ?? hostname
        return candidate.split(separator: ".").first.map(String.init) ?? ""
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
