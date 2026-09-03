import AppKit
import Foundation
import Observation
import os

@MainActor
@Observable
final class HerdrAppModel {
    struct ResultArtifactListRequest: Equatable, Sendable {
        let machineID: String
        let requestRevision: UInt64
        let eventBaseline: UInt64
    }

    private struct ResultArtifactReconciliationState {
        var latestEventRevision: UInt64 = 0
        var latestListRequestRevision: UInt64 = 0
        var eventRevisionByArtifactID: [String: UInt64] = [:]
    }

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
        var consecutiveBoringRefreshes = 0
        var lastRelevantEventAt: ContinuousClock.Instant?
        var lastEventID: Int?
        var didSweepDelivered = false
    }

    var workspaces: [HerdrWorkspace] = [] {
        didSet { rebuildPaneIndex() }
    }
    var alerts: [HerdrAlert] = []
    private(set) var resultArtifacts: [AgentResultArtifact] = []
    private(set) var resultArtifactPhases: [String: AgentResultArtifactPhase] = [:]
    private(set) var recentlyOpenedResultArtifactIDs: Set<String> = []
    private(set) var activityHistoryAlerts: [HerdrAlert] = []
    var isRefreshingActivity = false
    var activityFeedError: String?
    var connectionState: ConnectionState = .disconnected
    var selectedTab: AppTab = .workspaces
    var selectedWorkspaceID: String?
    var selectedPaneID: String?
    var workspacePath: [WorkspaceRoute] = []
    var isSidebarPresented = false
    var sidebarRecency: SidebarRecency = .all
    var collapsedSidebarWorkspaceIDs: Set<String>
    var collapsedSidebarMachineIDs: Set<String>
    var collapsedSidebarTabIDs: Set<String>
    var starredChatIDs: Set<String>
    private(set) var mutedHudSessionIDs: Set<String>
    /// Scoped pane id -> the dismissal that silenced its chip. Persisted under
    /// `herdr.hud.dismissedChips.v1`: this used to be in memory only, so every
    /// relaunch resurrected every chip the user had already cleared. Safe to
    /// persist only because the dismissal is keyed to an episode — see
    /// `HudChipDismissal`.
    private(set) var dismissedHudChips: [String: HudChipDismissal] = [:]
    /// Unsent composer text, per pane, so switching chats gives you that chat's
    /// own draft back instead of a blank field. In memory only: drafts carry
    /// pasted and dictated content, and their attachments are security-scoped
    /// URLs that cannot survive a relaunch anyway.
    private(set) var composerDrafts: [String: String] = [:]
    /// What the mounted pane session is showing, published so the window
    /// toolbar's scope picker can render and select a Git segment. The mode
    /// itself still belongs to whichever `PaneSessionView` is mounted — this is
    /// a read-only mirror, the same one-way shape as the `.herdrFocusPaneMode`
    /// commands that drive it.
    private(set) var currentPaneDetailMode: PaneDetailMode?
    private(set) var currentPaneGitIsAvailable = false
    @ObservationIgnored private var currentPaneDetailModeOwner: String?
    /// The pane ⇧⌘K last asked the sidebar to show, and a token that makes each
    /// ask distinct.
    ///
    /// A reveal cannot be inferred from `selectedPaneID` changing — revealing the
    /// pane you are already looking at is the common case, and that assignment is
    /// a no-op. Same reasoning as `HerdrShellState.showSession()`. The token is
    /// the shape `commandPaletteFocusRequest` already uses for a repeatable
    /// request.
    private(set) var sidebarRevealPaneID: String?
    private(set) var sidebarRevealToken = 0
    var searchText = ""
    var filter: WorkspaceFilter = .all
    var errorMessage: String? {
        didSet { isShowingError = errorMessage != nil }
    }
    var isShowingError = false
    var toastMessage: String?
    var lastUpdated: Date?
    var lastSyncedAt: Date?
    var fleetRevision = 0
    var refreshTick = 0
    var activeWorkRefreshTick = 0
    var isRefreshing = false
    var isSending = false
    private(set) var quickPiSessionMachineIDs: Set<String> = []
    var connectionGeneration = 0 {
        didSet {
            if connectionGeneration != oldValue {
                cancelDeferredRefreshes()
                discardPendingQuickPaneRoutes()
            }
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
    let activeWorkLegacyUI: Bool
    var smartAlertsEnabled: Bool
    var preferPrivateTranscription: Bool
    var showSessionTitles: Bool
    var remotePushConfigured = false
    var remotePushDeliveryVerified = false
    var remotePushRegistrationError: String?
    let cleanupPresenter = CleanupSheetPresenter()

    private let userDefaults: UserDefaults
    @ObservationIgnored private let resultArtifactOpenedLedger: AgentResultArtifactOpenedLedger
    @ObservationIgnored private let resultArtifactOpener: AgentResultArtifactOpener
    @ObservationIgnored private var resultArtifactRetirementTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var resultArtifactReconciliation: [String: ResultArtifactReconciliationState] = [:]
    /// Internal test seam for holding an open operation across a suspension.
    @ObservationIgnored var resultArtifactOpenOverride:
        (@MainActor (AgentResultArtifact, HerdrAPIClient?) async throws -> Void)?
    @ObservationIgnored private var runtimes: [String: MachineRuntime] = [:]
    @ObservationIgnored private var pendingPushToken: String?
    @ObservationIgnored private var pendingPaneRoutes: [PendingPaneRouteKey: PendingPaneRoute] = [:]
    @ObservationIgnored private var nextPaneRouteOrder: UInt64 = 0
    @ObservationIgnored private var pendingLocalAlertIDs: Set<String> = []
    /// Scoped pane IDs whose read acknowledgement has not yet been confirmed by
    /// the server. A refresh that overlaps the POST must not resurrect the
    /// server's stale unread copy.
    @ObservationIgnored private var pendingReadAcknowledgements: Set<String> = []
    /// Scoped pane IDs whose acknowledgement could not be sent because their
    /// machine did not have a connected client. Replayed when it returns live.
    @ObservationIgnored private var pendingRemoteReadAcknowledgements: Set<String> = []
    /// Scoped pane id -> the "episode" key (see `doneEpisodeKey(for:)`) it was
    /// last acknowledged-as-stale-done at. A `.done` status alone does not
    /// identify a unique episode: the same pane can read `.done`, answer
    /// again, and read `.done` again, so keying on status alone would either
    /// re-POST on every tap (if never remembered) or silently stop
    /// acknowledging forever (if remembered without a way to invalidate). This
    /// map lets `acknowledgeUnreadAlerts` post once per episode.
    @ObservationIgnored private var lastAckedDoneEpisodeByPaneID: [String: String] = [:]
    @ObservationIgnored private var promptOverrideSupport: [String: (generation: Int, supported: Bool, probedAt: Date)] = [:]
    @ObservationIgnored private var lastPresentedConnectionError: String?
    @ObservationIgnored private var lastBadgeCount: Int?
    @ObservationIgnored private var paneIndex: [String: PaneLocation] = [:]
    /// Internal test seam for deterministic URLProtocol-backed clients.
    @ObservationIgnored var clientFactory: (ServerConfiguration) -> HerdrAPIClient = {
        HerdrAPIClient(configuration: $0)
    }
    /// Internal test seam for verifying that focus hands control back to cmux.
    @ObservationIgnored var activateCmuxApplication: @MainActor () async throws -> Void = {
        try await CmuxApplicationActivator.activate()
    }
    @ObservationIgnored var fleetRefreshRetryBase: Duration = .seconds(2)
    @ObservationIgnored var fleetRefreshBaseWindow = Duration.milliseconds(200)
    @ObservationIgnored var fleetRefreshBackoffWindow = Duration.seconds(1)
    @ObservationIgnored var fleetRefreshBoringCycleThreshold = 5
    @ObservationIgnored var fleetRefreshQuietWindow = Duration.seconds(2)
#if DEBUG
    /// Test-only: when true, demo-mode `startHeadlessAgent` returns
    /// `threadRootRunId == <the new run's own id>` even when a
    /// `continueFromRunId` was passed, simulating the harness's
    /// reaped-session fallback (a continuation whose underlying pi
    /// session no longer exists, so the server starts a fresh thread).
    var demoForcesFreshThreadForTesting = false
#endif
    private static let connectionFailureGrace: TimeInterval = 10
    private static let paneAlertReadAttempts = 3
    private static let paneAlertReadRetryDelay: Duration = .milliseconds(400)
    private static let alertsLogger = Logger(subsystem: "dev.ronnierocha.herdr-harness", category: "alerts")

    private struct PaneLocation {
        let workspaceIndex: Int
        let paneIndex: Int
    }

    private enum PendingPaneRouteKey: Hashable {
        case direct
        case quick(machineID: String, requestID: String)
    }

    private struct PendingPaneRoute {
        var paneID: String?
        let order: UInt64
    }

    private struct ActivityFetchResult: Sendable {
        let machineID: String
        let alerts: [HerdrAlert]?
        let errorMessage: String?
    }

    init(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        userDefaults: UserDefaults = .standard
    ) {
        self.userDefaults = userDefaults
        let resultArtifactOpenedLedger = AgentResultArtifactOpenedLedger(userDefaults: userDefaults)
        self.resultArtifactOpenedLedger = resultArtifactOpenedLedger
        resultArtifactOpener = AgentResultArtifactOpener(
            cache: AgentResultArtifactCache(),
            ledger: resultArtifactOpenedLedger
        )
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
        activeWorkLegacyUI = arguments.contains("-HerdrActiveWorkLegacy")
            || (defaults.object(forKey: "herdr.activeWork.legacy") as? Bool ?? false)
        smartAlertsEnabled = defaults.object(forKey: "herdr.smartAlerts") as? Bool ?? true
        preferPrivateTranscription = defaults.object(forKey: "herdr.preferPrivateTranscription") as? Bool ?? true
        showSessionTitles = defaults.object(forKey: "herdr.herdPulse.showSessionTitles") as? Bool ?? true
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
        mutedHudSessionIDs = Set(defaults.stringArray(forKey: "herdr.hud.mutedSessions") ?? [])
        dismissedHudChips = Self.loadDismissedHudChips(defaults: defaults)

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
    var unreadPaneIDs: Set<String> {
        Set(alerts.lazy.filter { !$0.isRead }.map(\.scopedPaneID))
    }
    var workingCount: Int { workspaces.flatMap(\.panes).count(where: { $0.agentStatus == .working }) }
    var paneCount: Int { workspaces.reduce(0) { $0 + $1.paneCount } }
    var canControl: Bool { isDemoMode || connectionState == .live }
    var canControlPrimary: Bool {
        isDemoMode || machines.first.map { canControl(machineID: $0.id) } == true
    }
    var primaryConnectionState: ConnectionState {
        if isDemoMode { return .demo }
        guard let machineID = machines.first?.id else { return .disconnected }
        return connectionState(forMachine: machineID)
    }
    var activityFeedAlerts: [HerdrAlert] {
        ActivityFeed.merged(current: alerts, history: activityHistoryAlerts)
    }
    /// Artifacts remain here for a brief confirmation window after a successful
    /// open, allowing the HUD to render its green check before retiring them.
    var unopenedResultArtifacts: [AgentResultArtifact] {
        resultArtifacts.filter { artifact in
            resultArtifactPhase(id: artifact.id) != .opened
                || recentlyOpenedResultArtifactIDs.contains(artifact.id)
        }
    }

    func canControl(machineID: String) -> Bool {
        isDemoMode || connectionState(forMachine: machineID) == .live
    }

    func connectionState(forMachine id: String) -> ConnectionState {
        machineStates[id] ?? (isDemoMode ? .demo : .disconnected)
    }

    func resultArtifactPhase(id: String) -> AgentResultArtifactPhase {
        if let phase = resultArtifactPhases[id] { return phase }
        return resultArtifactOpenedLedger.contains(id) ? .opened : .available
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
        guard let id,
              let location = paneIndex[id],
              workspaces.indices.contains(location.workspaceIndex),
              workspaces[location.workspaceIndex].panes.indices.contains(location.paneIndex)
        else { return nil }
        return workspaces[location.workspaceIndex].panes[location.paneIndex]
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
        userDefaults.set(false, forKey: "herdr.demoMode")
        userDefaults.set(true, forKey: "herdr.completedSetup")
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
        userDefaults.set(true, forKey: "herdr.demoMode")
        userDefaults.set(true, forKey: "herdr.completedSetup")
        isDemoMode = true
        hasCompletedSetup = true
        resetConnectionState()
        connectionGeneration += 1
        loadDemo()
    }

    func leaveDemo() {
        userDefaults.set(false, forKey: "herdr.demoMode")
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
        userDefaults.set(true, forKey: "herdr.completedSetup")
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
        noteUserInteraction()
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

    func fetchGitStatus(for pane: HerdrPane) async throws -> WorkspaceGitStatus {
        if isDemoMode, let workspace = workspace(containing: pane) {
            return DemoData.gitStatus(for: workspace)
        }
        guard canControl(machineID: pane.machineID), self.pane(id: pane.id) != nil,
              let client = client(forMachine: pane.machineID) else {
            throw APIError.invalidResponse
        }
        return try await client.fetchGitStatus(paneID: pane.paneID)
    }

    func serverConfiguration(for pane: HerdrPane) -> ServerConfiguration? {
        guard !isDemoMode,
              self.pane(id: pane.id) != nil,
              let connection = runtimes[pane.machineID]?.connection,
              connection.generation == connectionGeneration
        else { return nil }
        return connection.configuration
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

    func startCleanup(
        machineID: String,
        workspaceIDs: [String],
        judgeCharter: String? = nil
    ) async throws -> CleanupStartRunResponse {
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
                workspaceIDs: workspaceIDs.isEmpty ? nil : workspaceIDs,
                judgeCharter: judgeCharter ?? HerdrPromptSettingsStore.storedOverride(
                    for: .cleanupJudgeCharter,
                    defaults: userDefaults
                )
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
        workspaceIDs: [String],
        onProgress: @Sendable (CleanupRunEnvelope) async -> Void = { _ in }
    ) async throws -> CleanupApplyResponse {
        if isDemoMode {
            let response = Self.demoCleanupApplyResponse(
                runID: runID,
                paneIDs: paneIDs,
                workspaceIDs: workspaceIDs
            )
            toastMessage = Self.cleanupApplyToast(for: response)
            return response
        }
        guard canControl(machineID: machineID), let client = client(forMachine: machineID) else {
            throw APIError.invalidResponse
        }
        let response = try await client.applyCleanupRun(
            id: runID,
            paneIDs: paneIDs,
            workspaceIDs: workspaceIDs,
            onProgress: onProgress
        )
        toastMessage = Self.cleanupApplyToast(for: response)
        return response
    }

    private static func demoCleanupApplyResponse(
        runID: String,
        paneIDs: [String],
        workspaceIDs: [String]
    ) -> CleanupApplyResponse {
        let workspacePaneIDs = [
            "w3": ["w3:p1", "w3:p2", "w3:p3"],
            "w9": ["w9:p1", "w9:p2"],
        ]
        let piSessionsByPaneID = [
            "w3:p1": CleanupPiSession(
                detected: true,
                sessionID: "pi_login_retry_8421",
                sessionFile: "~/.pi/agent/sessions/fix-login-flake/pi_login_retry_8421.jsonl",
                sessionName: "login-retry-8421",
                cwd: "/Users/demo/work/fix-login-flake",
                connected: true,
                active: true,
                idle: true,
                costUSD: 3.41,
                totalTokens: 186_420
            ),
            "w9:p1": CleanupPiSession(
                detected: true,
                sessionID: "pi_release_check_556",
                sessionFile: "~/.pi/agent/sessions/release-check/pi_release_check_556.jsonl",
                sessionName: "release-check",
                cwd: "/Users/demo/work/release-check",
                connected: true,
                active: true,
                idle: true,
                costUSD: 2.46,
                totalTokens: 121_870
            ),
        ]
        let paneTitles = [
            "w3:p1": "pi · fix-login-flake",
            "w9:p1": "pi · release-check",
        ]
        let workspaceTitles = [
            "w3": "Fix Login Flake",
            "w9": "Release Check",
        ]

        var affectedPiPaneIDs = paneIDs.filter { piSessionsByPaneID[$0] != nil }
        for workspaceID in workspaceIDs {
            for paneID in workspacePaneIDs[workspaceID] ?? [] where piSessionsByPaneID[paneID] != nil && !affectedPiPaneIDs.contains(paneID) {
                affectedPiPaneIDs.append(paneID)
            }
        }

        let piResults = affectedPiPaneIDs.compactMap { paneID -> CleanupPiSessionApplyResult? in
            guard let session = piSessionsByPaneID[paneID] else { return nil }
            return CleanupPiSessionApplyResult(
                paneID: paneID,
                sessionID: session.sessionID,
                wasActive: session.active,
                quitAttempted: session.active,
                quitSucceeded: session.active,
                closeOutcome: "closed",
                reason: nil
            )
        }
        let ledgerRecords = affectedPiPaneIDs.compactMap { paneID -> CleanupLedgerRecord? in
            guard let session = piSessionsByPaneID[paneID] else { return nil }
            let workspaceID = paneID.split(separator: ":", maxSplits: 1).first.map(String.init) ?? "demo"
            let closedWithWorkspace = workspaceIDs.contains(workspaceID)
            let endedSession = CleanupPiSession(
                detected: session.detected,
                sessionID: session.sessionID,
                sessionFile: session.sessionFile,
                sessionName: session.sessionName,
                cwd: session.cwd,
                connected: false,
                active: false,
                idle: session.idle,
                costUSD: session.costUSD,
                totalTokens: session.totalTokens
            )
            return CleanupLedgerRecord(
                cleanupRunID: runID,
                timestamp: "2026-08-21T20:06:12Z",
                workspace: CleanupLedgerWorkspace(
                    id: workspaceID,
                    title: workspaceTitles[workspaceID] ?? workspaceID
                ),
                pane: CleanupLedgerPane(
                    id: paneID,
                    title: paneTitles[paneID] ?? paneID,
                    tabID: "tab-\(workspaceID)",
                    cwd: session.cwd
                ),
                piSession: endedSession,
                quit: CleanupLedgerRecord.Quit(
                    attempted: session.active,
                    succeeded: session.active,
                    outcome: session.active ? "ended" : "not_needed",
                    error: nil
                ),
                close: CleanupLedgerRecord.Close(
                    scope: closedWithWorkspace ? "workspace" : "pane",
                    outcome: "closed",
                    error: nil
                )
            )
        }
        let workspaceCoveredPaneIDs = Set(workspaceIDs.flatMap { workspacePaneIDs[$0] ?? [] })
        let deduplicatedPaneIDs = paneIDs.filter { workspaceCoveredPaneIDs.contains($0) }
        let appliedPaneIDs = paneIDs.filter { !workspaceCoveredPaneIDs.contains($0) }

        return CleanupApplyResponse(
            applied: CleanupAppliedItems(panes: appliedPaneIDs, workspaces: workspaceIDs),
            skipped: [],
            piSessions: CleanupPiSessionApplySummary(
                ended: piResults.count(where: \.quitSucceeded),
                failed: piResults.count(where: { $0.quitAttempted && !$0.quitSucceeded }),
                results: piResults
            ),
            ledger: CleanupLedgerSummary(
                path: "~/.config/herdr-harness/cleanup/pane-session-ledger.jsonl",
                recordsAppended: ledgerRecords.count,
                records: ledgerRecords
            ),
            deduplicatedPaneIDs: deduplicatedPaneIDs,
            complete: true
        )
    }

    private static func cleanupApplyToast(for response: CleanupApplyResponse) -> String {
        let paneCount = response.applied.panes.count
        let workspaceCount = response.applied.workspaces.count
        let endedSessionCount = response.piSessions?.ended ?? 0
        let recordedCount = response.ledger?.recordsAppended ?? 0
        let skippedCount = response.skipped.count

        var sentences: [String] = []
        if let error = response.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            sentences.append("Cleanup stopped early: \(error)")
        }
        if paneCount > 0 || workspaceCount > 0 {
            var closedItems: [String] = []
            if paneCount > 0 {
                closedItems.append("\(paneCount) \(paneCount == 1 ? "pane" : "panes")")
            }
            if workspaceCount > 0 {
                closedItems.append("\(workspaceCount) \(workspaceCount == 1 ? "workspace" : "workspaces")")
            }
            sentences.append("Closed \(closedItems.joined(separator: " and "))")
        } else {
            sentences.append("No panes or workspaces closed")
        }
        if endedSessionCount > 0 {
            sentences.append("Ended \(endedSessionCount) Pi \(endedSessionCount == 1 ? "session" : "sessions")")
        }
        if recordedCount > 0 {
            sentences.append("Saved \(recordedCount) pane-session \(recordedCount == 1 ? "record" : "records")")
        }
        if skippedCount > 0 {
            sentences.append("Skipped \(skippedCount) \(skippedCount == 1 ? "item" : "items")")
        }
        return sentences.joined(separator: ". ") + "."
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
            runContext: "machine \(target.machineID), workspaces \(target.requestedWorkspaceIDs.isEmpty ? "all" : target.requestedWorkspaceIDs.joined(separator: ","))",
            start: { _ in
                try await self.startCleanup(machineID: target.machineID, workspaceIDs: target.requestedWorkspaceIDs)
            },
            fetch: { runID in
                try await self.fetchCleanupRun(machineID: target.machineID, runID: runID)
            },
            applyWithProgress: { runID, paneIDs, workspaceIDs, onProgress in
                try await self.applyCleanupRun(
                    machineID: target.machineID,
                    runID: runID,
                    paneIDs: paneIDs,
                    workspaceIDs: workspaceIDs,
                    onProgress: onProgress
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

    func fetchWorkInbox() async throws -> WorkInboxResponse {
        if isDemoMode { return DemoData.workInbox }
        guard let client = primaryClient else {
            throw APIError.noActiveConnection(machineID: machines.first?.name ?? "primary")
        }
        return try await client.fetchWorkInbox()
    }

    func fetchActiveWork() async throws -> ActiveWorkResponse {
        if isDemoMode { return DemoData.activeWork }
        guard let client = primaryClient else {
            throw APIError.noActiveConnection(machineID: machines.first?.name ?? "primary")
        }
        return try await client.fetchActiveWork()
    }

    func setupActiveWorkJira(key: String) async throws -> ActiveWorkItem {
        if isDemoMode {
            guard let item = DemoData.activeWork.items.first else { throw APIError.invalidResponse }
            return item
        }
        guard canControlPrimary, let client = primaryClient else { throw APIError.invalidResponse }
        return try await client.setupActiveWorkJira(key: key).item
    }

    func createActiveWorkItem(
        kind: String,
        title: String,
        summary: String
    ) async throws -> ActiveWorkItem {
        if isDemoMode {
            guard let item = DemoData.activeWork.items.first else { throw APIError.invalidResponse }
            return item
        }
        guard canControlPrimary, let client = primaryClient else { throw APIError.invalidResponse }
        return try await client.createActiveWorkItem(
            ActiveWorkCreateItemRequest(
                kind: kind,
                title: title,
                summary: summary,
                currentStageKey: nil
            )
        ).item
    }

    func transitionActiveWorkItem(
        _ item: ActiveWorkItem,
        to stage: ActiveWorkPipelineStage
    ) async throws -> ActiveWorkItem {
        if isDemoMode { return item }
        guard canControlPrimary, let client = primaryClient else { throw APIError.invalidResponse }
        let checkpoint = stage.checkpoint?.lowercased() ?? "none"
        let isHumanCheckpoint = checkpoint.contains("human") || checkpoint.contains("owner")
        let response = try await client.transitionActiveWorkItem(
            id: item.id,
            requestBody: ActiveWorkTransitionRequest(
                toStageKey: stage.key,
                expectedRevision: item.revision,
                note: nil,
                attention: isHumanCheckpoint ? "human" : "none",
                checkpointState: isHumanCheckpoint ? "pending" : nil
            )
        )
        return response.item
    }

    func setActiveWorkLifecycle(
        _ item: ActiveWorkItem,
        lifecycle: String
    ) async throws -> ActiveWorkItem {
        if isDemoMode { return item }
        guard canControlPrimary, let client = primaryClient else { throw APIError.invalidResponse }
        return try await client.patchActiveWorkItem(
            id: item.id,
            requestBody: ActiveWorkPatchItemRequest(
                lifecycle: lifecycle,
                expectedRevision: item.revision
            )
        ).item
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
        userDefaults.set(enabled, forKey: "herdr.preferPrivateTranscription")
    }

    func setShowSessionTitles(_ enabled: Bool) {
        showSessionTitles = enabled
        userDefaults.set(enabled, forKey: "herdr.herdPulse.showSessionTitles")
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
        #if DEBUG
        if isDemoMode, let replay = HerdrPiReplay.shared, replay.handles(pane) {
            return try replay.snapshot()
        }
        #endif
        guard !isDemoMode, canControl(machineID: pane.machineID), self.pane(id: pane.id) != nil,
              let client = client(forMachine: pane.machineID) else {
            throw APIError.invalidResponse
        }
        return try await client.fetchPiConversationSnapshot(paneID: pane.paneID)
    }

    /// A pane's newest finished answer, without following its stream.
    ///
    /// The HUD chips need this for a pane whose session view is not on screen,
    /// so there is no `PiConversationStore` to read. Projecting the snapshot
    /// through the same reducer keeps the text identical to what the chat's own
    /// response-audio control would read.
    func latestCompletedAssistantResponse(for pane: HerdrPane) async throws -> String? {
        let snapshot = try await fetchPiConversationSnapshot(for: pane)
        guard snapshot.available else { return nil }
        var reducer = PiConversationReducer()
        reducer.replace(with: snapshot)
        return reducer.turns.latestCompletedAssistantText
    }

    func fetchResponseAudioCapabilities(for pane: HerdrPane) async throws -> ResponseAudioCapabilities {
        guard !isDemoMode, canControl(machineID: pane.machineID), self.pane(id: pane.id) != nil,
              let client = client(forMachine: pane.machineID) else {
            return .unavailable
        }
        return try await client.fetchResponseAudioCapabilities()
    }

    func prepareResponseAudio(
        action: ResponseAudioAction,
        text: String,
        for pane: HerdrPane
    ) async throws -> ResponseAudioPrepareResponse {
        guard !isDemoMode, canControl(machineID: pane.machineID), self.pane(id: pane.id) != nil,
              let client = client(forMachine: pane.machineID) else {
            throw APIError.invalidResponse
        }
        return try await client.prepareResponseAudio(action: action, text: text)
    }

    func synthesizeResponseAudio(
        text: String,
        for pane: HerdrPane
    ) async throws -> ResponseAudioSpeechResponse {
        guard !isDemoMode, canControl(machineID: pane.machineID), self.pane(id: pane.id) != nil,
              let client = client(forMachine: pane.machineID) else {
            throw APIError.invalidResponse
        }
        return try await client.synthesizeResponseAudio(text: text)
    }

    func fetchResponseAudioCapabilities(forMachine machineID: String) async throws -> ResponseAudioCapabilities {
        guard !isDemoMode, canControl(machineID: machineID),
              let client = client(forMachine: machineID) else {
            return .unavailable
        }
        return try await client.fetchResponseAudioCapabilities()
    }

    func fetchAgentModels(machineID: String? = nil) async throws -> AgentModelCatalogResponse {
        if isDemoMode {
            return AgentModelCatalogResponse(
                ok: true,
                models: [
                    PiAvailableModel(
                        provider: "openai-codex",
                        modelID: "gpt-5.6-luna",
                        name: "GPT-5.6 Luna",
                        reasoning: true,
                        contextWindow: 272_000,
                        supportsImages: true
                    ),
                    PiAvailableModel(
                        provider: "anthropic",
                        modelID: "claude-sonnet-4-5",
                        name: "Claude Sonnet 4.5",
                        reasoning: true,
                        contextWindow: 200_000
                    ),
                    PiAvailableModel(
                        provider: "custom-lux-dspark",
                        modelID: "qwen3.8-27b-nvfp4-dspark",
                        name: "Qwen 3.8 27B",
                        reasoning: true,
                        contextWindow: 98_300
                    ),
                ],
                defaultModel: PiModelIdentity(
                    provider: "openai-codex",
                    id: "gpt-5.6-luna",
                    name: "GPT-5.6 Luna"
                )
            )
        }
        if let machineID {
            guard canControl(machineID: machineID), let client = client(forMachine: machineID) else {
                throw APIError.noActiveConnection(
                    machineID: machines.first(where: { $0.id == machineID })?.name ?? machineID
                )
            }
            return try await client.fetchAgentModels()
        }
        guard let client = primaryClient else { throw APIError.invalidResponse }
        return try await client.fetchAgentModels()
    }

    func fetchAgentPromptDefaults(machineID: String? = nil) async throws -> AgentPromptDefaultsResponse {
        if isDemoMode {
            let response = AgentPromptDefaultsResponse(
                ok: true,
                prompts: [
                    "act": HerdrPromptID.hudActCharter.builtInDefault,
                    "ask": HerdrPromptID.agentAskCharter.builtInDefault,
                    "cleanupJudge": HerdrPromptID.cleanupJudgeCharter.builtInDefault,
                ]
            )
            if let machineID { promptOverrideSupport[machineID] = (connectionGeneration, true, .now) }
            return response
        }
        let client: HerdrAPIClient?
        if let machineID {
            guard canControl(machineID: machineID) else {
                throw APIError.noActiveConnection(
                    machineID: machines.first(where: { $0.id == machineID })?.name ?? machineID
                )
            }
            client = self.client(forMachine: machineID)
        } else {
            client = primaryClient
        }
        guard let client else { throw APIError.invalidResponse }
        do {
            let response = try await client.fetchAgentPromptDefaults()
            if let machineID { promptOverrideSupport[machineID] = (connectionGeneration, true, .now) }
            return response
        } catch let APIError.server(status, _) where status == 404 {
            if let machineID { promptOverrideSupport[machineID] = (connectionGeneration, false, .now) }
            throw AgentPromptDefaultsError.unsupported
        }
    }

    func supportsPromptOverrides(machineID: String) async -> Bool {
        if isDemoMode { return true }
        if let cached = promptOverrideSupport[machineID],
           cached.generation == connectionGeneration,
           cached.supported || Date.now.timeIntervalSince(cached.probedAt) < 60 {
            return cached.supported
        }
        do {
            _ = try await fetchAgentPromptDefaults(machineID: machineID)
            return promptOverrideSupport[machineID]?.supported ?? true
        } catch is AgentPromptDefaultsError {
            return promptOverrideSupport[machineID]?.supported ?? false
        } catch {
            return false
        }
    }

    func prepareResponseAudio(
        action: ResponseAudioAction,
        text: String,
        forMachine machineID: String
    ) async throws -> ResponseAudioPrepareResponse {
        guard !isDemoMode, canControl(machineID: machineID),
              let client = client(forMachine: machineID) else {
            throw APIError.invalidResponse
        }
        return try await client.prepareResponseAudio(action: action, text: text)
    }

    func synthesizeResponseAudio(
        text: String,
        forMachine machineID: String
    ) async throws -> ResponseAudioSpeechResponse {
        guard !isDemoMode, canControl(machineID: machineID),
              let client = client(forMachine: machineID) else {
            throw APIError.invalidResponse
        }
        return try await client.synthesizeResponseAudio(text: text)
    }

    func piConversationEvents(
        for pane: HerdrPane,
        after cursor: String?
    ) async -> AsyncThrowingStream<PiConversationStreamEvent, any Error>? {
        #if DEBUG
        if isDemoMode, let replay = HerdrPiReplay.shared, replay.handles(pane) {
            return replay.events()
        }
        #endif
        guard !isDemoMode, canControl(machineID: pane.machineID), self.pane(id: pane.id) != nil,
              let client = client(forMachine: pane.machineID) else { return nil }
        return await client.piConversationEvents(paneID: pane.paneID, after: cursor)
    }

    func sendPiConversationPrompt(
        _ text: String,
        disposition: PiPromptDisposition,
        to pane: HerdrPane
    ) async throws {
        noteUserInteraction(machineID: pane.machineID)
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        #if DEBUG
        if isDemoMode, let replay = HerdrPiReplay.shared, replay.handles(pane) {
            replay.arm()
            return
        }
        #endif
        guard !prompt.isEmpty,
              !isDemoMode,
              canControl(machineID: pane.machineID),
              self.pane(id: pane.id) != nil,
              let client = client(forMachine: pane.machineID)
        else { throw APIError.invalidResponse }
        try await client.sendPiPrompt(paneID: pane.paneID, text: prompt, disposition: disposition)
    }

    func sendPiPrompt(paneID scopedPaneID: String, text: String) async throws {
        guard let scope = MachineScopedID.split(scopedPaneID) else {
            throw APIError.invalidResponse
        }
        if isDemoMode { return }
        guard canControl(machineID: scope.machineID), let client = client(forMachine: scope.machineID) else {
            throw APIError.noActiveConnection(
                machineID: machines.first(where: { $0.id == scope.machineID })?.name ?? scope.machineID
            )
        }
        try await client.sendPiPrompt(paneID: scope.rawID, text: text, disposition: .prompt)
    }

    func abortPiConversation(for pane: HerdrPane) async throws {
        noteUserInteraction(machineID: pane.machineID)
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
        noteUserInteraction(machineID: pane.machineID)
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
        noteUserInteraction(machineID: pane.machineID)
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
        noteUserInteraction(machineID: pane.machineID)
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
        noteUserInteraction(machineID: pane.machineID)
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
        noteUserInteraction(machineID: pane.machineID)
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

    func compactPiChat(in pane: HerdrPane) async {
        noteUserInteraction(machineID: pane.machineID)
        if isDemoMode {
            toastMessage = "compaction started"
            return
        }
        guard canControl(machineID: pane.machineID), self.pane(id: pane.id) != nil,
              let client = client(forMachine: pane.machineID) else { return }
        do {
            if pane.piSemantic?.capabilities.compact == true {
                try await client.compactPiConversation(paneID: pane.paneID)
            } else {
                try await client.sendText(toPane: pane.paneID, text: "/compact", submit: false)
                try await client.sendKeys(toPane: pane.paneID, keys: ["enter"])
            }
            toastMessage = "compaction started"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func endPiSession(in pane: HerdrPane) async {
        noteUserInteraction(machineID: pane.machineID)
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

    func endPiSessionAndClosePane(in pane: HerdrPane) async {
        noteUserInteraction(machineID: pane.machineID)
        if isDemoMode {
            toastMessage = "ended pi and closed the pane"
            return
        }
        guard canControl(machineID: pane.machineID),
              let currentPane = self.pane(id: pane.id),
              let client = client(forMachine: pane.machineID) else { return }

        guard currentPane.piSemantic?.connected == true else {
            await close(currentPane)
            return
        }
        do {
            try await client.sendText(toPane: pane.paneID, text: "/quit", submit: true)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        for _ in 0..<12 {
            do {
                try await refresh(
                    machineID: pane.machineID,
                    using: client,
                    showSpinner: false,
                    expectedGeneration: connectionGeneration
                )
            } catch {
                break
            }
            guard let refreshedPane = self.pane(id: pane.id) else {
                toastMessage = "ended pi and closed the pane"
                return
            }
            if refreshedPane.piSemantic?.connected != true {
                await close(refreshedPane)
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        toastMessage = "pi didn't quit — pane left open"
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
        noteUserInteraction(machineID: workspace.machineID)
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
            try await activateCmuxApplication()
        }
    }

    func focusAndZoom(_ pane: HerdrPane) async {
        await perform("Focused + zoomed on Mac", machineID: pane.machineID) { client in
            try await client.focusPane(id: pane.paneID)
            try await client.zoomPane(id: pane.paneID, mode: "on")
            try await activateCmuxApplication()
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
            try await activateCmuxApplication()
        }
    }

    func rename(_ workspace: HerdrWorkspace, label: String) async {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await perform("Workspace renamed", machineID: workspace.machineID) { client in
            try await client.renameWorkspace(id: workspace.workspaceID, label: trimmed)
        }
    }

    func rename(_ tab: HerdrTab, label: String) async {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await perform("Tab renamed", machineID: tab.machineID) { client in
            try await client.renameTab(id: tab.tabID, label: trimmed)
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

    func isCreatingQuickPiSession(machineID: String?) -> Bool {
        guard let machineID else { return false }
        return quickPiSessionMachineIDs.contains(machineID)
    }

    func createQuickPiSession(
        machineID: String? = nil,
        workspaceID: String? = nil,
        tabID: String? = nil,
        cwd: String? = nil,
        sessionFile: String? = nil,
        sessionID: String? = nil
    ) async {
        if isDemoMode {
            toastMessage = "quick pi sessions need a live connection"
            return
        }
        guard let targetMachineID = machineID ?? machines.first?.id else {
            toastMessage = "Reconnect before controlling Herdr"
            return
        }
        guard !quickPiSessionMachineIDs.contains(targetMachineID) else { return }
        guard canControl(machineID: targetMachineID), let client = client(forMachine: targetMachineID) else {
            toastMessage = "Reconnect before controlling Herdr"
            return
        }
        noteUserInteraction(machineID: targetMachineID)
        quickPiSessionMachineIDs.insert(targetMachineID)
        defer { quickPiSessionMachineIDs.remove(targetMachineID) }

        let label = Date.now.formatted(.dateTime.month(.abbreviated).day().hour().minute()).lowercased()
        let requestID = UUID().uuidString
        let pendingRouteKey = beginQuickPaneRoute(
            machineID: targetMachineID,
            requestID: requestID
        )
        let generation = connectionGeneration
        do {
            let response = try await createQuickPiSessionWithRetry(
                client: client,
                label: label,
                requestID: requestID,
                workspaceID: workspaceID,
                tabID: tabID,
                cwd: cwd,
                sessionFile: sessionFile,
                sessionID: sessionID
            )
            guard generation == connectionGeneration else { return }
            let scopedPaneID = MachineScopedID.compose(
                machineID: targetMachineID,
                rawID: response.paneID
            )
            // Resolve immediately when topology is already current. Otherwise,
            // retain this machine/request route until a later refresh observes it.
            completeQuickPaneRoute(pendingRouteKey, paneID: scopedPaneID)
            try? await refresh(
                machineID: targetMachineID,
                using: client,
                showSpinner: false,
                expectedGeneration: generation
            )
            guard generation == connectionGeneration else { return }
            toastMessage = "pi session ready"
        } catch {
            guard generation == connectionGeneration else { return }
            cancelPendingPaneRoute(pendingRouteKey)
            errorMessage = error.localizedDescription
        }
    }

    func spawnPrReviewSession(_ payload: ActiveWorkSpawnReviewPayload) async {
        if isDemoMode {
            toastMessage = "review spawns need a live connection"
            return
        }
        guard let targetMachineID = machines.first?.id,
              canControl(machineID: targetMachineID),
              let client = client(forMachine: targetMachineID)
        else {
            toastMessage = "Reconnect before controlling Herdr"
            return
        }
        noteUserInteraction(machineID: targetMachineID)
        let requestID = UUID().uuidString
        let prNumberText = payload.prNumber.map(String.init) ?? "review"
        let label = "pr\(prNumberText)-\(payload.stageKey)"
        let generation = connectionGeneration
        do {
            let response = try await createQuickPiSessionWithRetry(
                client: client,
                label: label,
                requestID: requestID,
                workspaceID: nil,
                tabID: nil,
                cwd: nil,
                sessionFile: nil,
                sessionID: nil,
                workspaceLabel: "PR Reviews",
                tabLabel: payload.tabLabel,
                reuseNamedTab: true
            )
            guard generation == connectionGeneration else { return }
            try await client.sendPiPrompt(
                paneID: response.paneID,
                text: payload.prompt,
                disposition: .prompt,
                waitForIdle: true
            )
            let sessionID = "spawn:\(payload.workID):\(payload.stageKey):\(response.paneID)"
            let observation = ActiveWorkIngestionBody(
                source: "pr-review-watch",
                idempotencyKey: "pr-review-watch:\(sessionID)",
                observedAt: ISO8601DateFormatter().string(from: Date()),
                selector: .init(workItemID: payload.workID),
                stages: [
                    .init(
                        stageKey: payload.stageKey,
                        state: "active",
                        piSessions: [
                            .init(
                                externalID: sessionID,
                                title: "PR #\(prNumberText) · \(payload.skill)",
                                provider: "pi",
                                status: "running",
                                machineID: targetMachineID,
                                workspaceID: response.workspaceID,
                                paneID: response.paneID,
                                nativeSessionID: response.sessionID ?? "",
                                role: "review",
                                metadata: [
                                    "workspace_label": "PR Reviews",
                                    "tab": payload.tabLabel,
                                    "skill": payload.skill,
                                ]
                            )
                        ]
                    )
                ]
            )
            try await client.ingestActiveWork(observation)
            toastMessage = "PR #\(prNumberText) — \(payload.skill) running in PR Reviews"
            try? await refresh(
                machineID: targetMachineID,
                using: client,
                showSpinner: false,
                expectedGeneration: generation
            )
        } catch {
            guard generation == connectionGeneration else { return }
            toastMessage = "Review spawn failed — \(error.localizedDescription)"
        }
    }

    func createLinkedQuickPiSession(
        machineID: String,
        label: String,
        workspaceLabel: String?,
        tabLabel: String?
    ) async throws -> HerdrPane {
        if isDemoMode {
            guard let workspace = workspaces.first(where: { $0.machineID == machineID }),
                  let pane = workspace.panes.first else {
                throw APIError.invalidResponse
            }
            return pane
        }
        guard canControl(machineID: machineID), let client = client(forMachine: machineID) else {
            throw APIError.noActiveConnection(
                machineID: machines.first(where: { $0.id == machineID })?.name ?? machineID
            )
        }
        guard !quickPiSessionMachineIDs.contains(machineID) else { throw APIError.invalidResponse }
        noteUserInteraction(machineID: machineID)
        quickPiSessionMachineIDs.insert(machineID)
        defer { quickPiSessionMachineIDs.remove(machineID) }
        let requestID = UUID().uuidString
        let generation = connectionGeneration
        let supportsOverrides = await supportsPromptOverrides(machineID: machineID)
        let response = try await client.createQuickPiSession(
            label: label,
            requestID: requestID,
            workspaceLabel: supportsOverrides ? workspaceLabel : nil,
            tabLabel: supportsOverrides ? tabLabel : nil,
            reuseNamedTab: supportsOverrides ? false : nil
        )
        guard generation == connectionGeneration else { throw CancellationError() }
        let scopedPaneID = MachineScopedID.compose(machineID: machineID, rawID: response.paneID)
        for attempt in 0..<4 {
            try await refresh(machineID: machineID, using: client, showSpinner: false, expectedGeneration: generation)
            if let pane = pane(id: scopedPaneID) {
                return pane
            }
            if attempt < 3 { try await Task.sleep(for: .milliseconds(200)) }
        }
        throw APIError.invalidResponse
    }

    private func createQuickPiSessionWithRetry(
        client: HerdrAPIClient,
        label: String,
        requestID: String,
        workspaceID: String?,
        tabID: String?,
        cwd: String?,
        sessionFile: String?,
        sessionID: String?,
        workspaceLabel: String? = nil,
        tabLabel: String? = nil,
        reuseNamedTab: Bool? = nil
    ) async throws -> QuickPiSessionResponse {
        do {
            return try await client.createQuickPiSession(
                label: label,
                requestID: requestID,
                workspaceID: workspaceID,
                tabID: tabID,
                cwd: cwd,
                sessionFile: sessionFile,
                sessionID: sessionID,
                workspaceLabel: workspaceLabel,
                tabLabel: tabLabel,
                reuseNamedTab: reuseNamedTab
            )
        } catch {
            guard Self.isTransientQuickPiSessionError(error) else { throw error }
            try await Task.sleep(for: .milliseconds(150))
            return try await client.createQuickPiSession(
                label: label,
                requestID: requestID,
                workspaceID: workspaceID,
                tabID: tabID,
                cwd: cwd,
                sessionFile: sessionFile,
                sessionID: sessionID,
                workspaceLabel: workspaceLabel,
                tabLabel: tabLabel,
                reuseNamedTab: reuseNamedTab
            )
        }
    }

    private static func isTransientQuickPiSessionError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .networkConnectionLost,
            .dnsLookupFailed,
            .notConnectedToInternet,
        ].contains(urlError.code)
    }

    func refreshActivityFeed() async {
        guard !isRefreshingActivity else { return }
        isRefreshingActivity = true
        activityFeedError = nil
        defer { isRefreshingActivity = false }

        if isDemoMode {
            activityHistoryAlerts = alerts
            return
        }

        let targets = machines.compactMap { machine -> (HerdrMachine, HerdrAPIClient)? in
            guard let client = client(forMachine: machine.id) else { return nil }
            return (machine, client)
        }
        var results = await withTaskGroup(of: ActivityFetchResult.self) { group in
            for (machine, client) in targets {
                group.addTask {
                    do {
                        let response = try await client.fetchAlerts(limit: 500)
                        return ActivityFetchResult(
                            machineID: machine.id,
                            alerts: response.alerts.map { $0.stamped(machineID: machine.id) },
                            errorMessage: nil
                        )
                    } catch {
                        return ActivityFetchResult(
                            machineID: machine.id,
                            alerts: nil,
                            errorMessage: error.localizedDescription
                        )
                    }
                }
            }

            var fetched: [ActivityFetchResult] = []
            for await result in group { fetched.append(result) }
            return fetched
        }

        let targetMachineIDs = Set(targets.map { $0.0.id })
        for machine in machines where !targetMachineIDs.contains(machine.id) {
            results.append(ActivityFetchResult(
                machineID: machine.id,
                alerts: nil,
                errorMessage: "No active connection"
            ))
        }

        let refreshedMachineIDs = Set(results.compactMap { $0.alerts == nil ? nil : $0.machineID })
        var merged = activityHistoryAlerts.filter { !refreshedMachineIDs.contains($0.machineID) }
        for result in results {
            if let fresh = result.alerts { merged.append(contentsOf: fresh) }
        }
        activityHistoryAlerts = ActivityFeed.merged(current: [], history: merged)

        let failures = results.compactMap { result -> String? in
            guard let message = result.errorMessage else { return nil }
            let name = machines.first(where: { $0.id == result.machineID })?.name ?? result.machineID
            return "\(name): \(message)"
        }
        activityFeedError = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    func startHeadlessAgent(
        prompt: String,
        machineID: String,
        mode: HeadlessAgentRunMode = .ask,
        model: String? = nil,
        thinkingLevel: String? = nil,
        attachments: [HeadlessAgentAttachment]? = nil,
        continueFromRunId: String? = nil,
        systemPrompt: String? = nil
    ) async throws -> HeadlessAgentRun {
        if isDemoMode {
            let now = HerdrTimestamp.string(from: .now)
            let id = "demo-agent-\(UUID().uuidString)"
            return HeadlessAgentRun(
                id: id,
                status: .completed,
                mode: mode,
                model: model,
                thinkingLevel: thinkingLevel,
                prompt: prompt,
                response: "This is a demo Agent response. On a live machine, Pi answers from your home folder with a read-only snapshot of the current Herdr fleet.",
                error: nil,
                createdAt: now,
                startedAt: now,
                finishedAt: now,
                sessionID: "demo-session",
                sessionFile: "demo-session.jsonl",
                costUSD: 0,
                promotedWorkspaceID: nil,
                promotedPaneID: nil,
                attachments: attachments?.map(\.filename),
                steps: nil,
                stepsTruncated: nil,
                threadRootRunId: {
#if DEBUG
                    if demoForcesFreshThreadForTesting { return id }
#endif
                    return continueFromRunId ?? id
                }()
            )
        }
        guard canControl(machineID: machineID), let client = client(forMachine: machineID) else {
            throw APIError.noActiveConnection(
                machineID: machines.first(where: { $0.id == machineID })?.name ?? machineID
            )
        }
        return try await client.startHeadlessAgent(
            prompt: prompt,
            mode: mode,
            model: model,
            thinkingLevel: thinkingLevel,
            attachments: attachments,
            continueFromRunId: continueFromRunId,
            systemPrompt: systemPrompt
        ).run
    }

    func fetchHeadlessAgent(runID: String, machineID: String) async throws -> HeadlessAgentRun {
        guard let client = client(forMachine: machineID) else {
            throw APIError.noActiveConnection(
                machineID: machines.first(where: { $0.id == machineID })?.name ?? machineID
            )
        }
        return try await client.fetchHeadlessAgent(id: runID).run
    }

    func cancelHeadlessAgent(runID: String, machineID: String) async throws -> HeadlessAgentRun {
        guard let client = client(forMachine: machineID) else {
            throw APIError.noActiveConnection(
                machineID: machines.first(where: { $0.id == machineID })?.name ?? machineID
            )
        }
        return try await client.cancelHeadlessAgent(id: runID).run
    }

    func deleteHeadlessAgent(runID: String, machineID: String) async throws {
        if isDemoMode { return }
        guard let client = client(forMachine: machineID) else {
            throw APIError.noActiveConnection(
                machineID: machines.first(where: { $0.id == machineID })?.name ?? machineID
            )
        }
        _ = try await client.deleteHeadlessAgent(id: runID)
    }

    func promoteHeadlessAgent(
        runID: String,
        machineID: String,
        workspaceID: String?
    ) async throws -> HeadlessAgentPromotionResult {
        if isDemoMode {
            guard let workspace = workspaces.first(where: {
                $0.machineID == machineID && (workspaceID == nil || $0.workspaceID == workspaceID)
            }), let pane = workspace.panes.first else {
                throw APIError.invalidResponse
            }
            let now = HerdrTimestamp.string(from: .now)
            return HeadlessAgentPromotionResult(
                run: HeadlessAgentRun(
                    id: runID,
                    status: .promoted,
                    mode: .ask,
                    model: nil,
                    thinkingLevel: nil,
                    prompt: "Demo prompt",
                    response: "Demo response",
                    error: nil,
                    createdAt: now,
                    startedAt: now,
                    finishedAt: now,
                    sessionID: "demo-session",
                    sessionFile: "demo-session.jsonl",
                    costUSD: 0,
                    promotedWorkspaceID: workspace.workspaceID,
                    promotedPaneID: pane.paneID,
                    attachments: nil,
                    steps: nil,
                    stepsTruncated: nil,
                    threadRootRunId: nil
                ),
                pane: pane
            )
        }

        guard canControl(machineID: machineID),
              workspaceID == nil || workspaces.contains(where: {
                  $0.machineID == machineID && $0.workspaceID == workspaceID
              }),
              let client = client(forMachine: machineID) else {
            throw APIError.noActiveConnection(
                machineID: machines.first(where: { $0.id == machineID })?.name ?? machineID
            )
        }
        let envelope = try await client.promoteHeadlessAgent(id: runID, workspaceID: workspaceID)
        guard let rawPaneID = envelope.run.promotedPaneID?.nonEmpty else {
            throw APIError.invalidResponse
        }
        let scopedPaneID = MachineScopedID.compose(machineID: machineID, rawID: rawPaneID)
        let generation = connectionGeneration
        for attempt in 0..<4 {
            try await refresh(
                machineID: machineID,
                using: client,
                showSpinner: false,
                expectedGeneration: generation
            )
            if let pane = pane(id: scopedPaneID) {
                toastMessage = "Agent continued as a chat"
                return HeadlessAgentPromotionResult(run: envelope.run, pane: pane)
            }
            if attempt < 3 { try await Task.sleep(for: .milliseconds(200)) }
        }
        throw APIError.invalidResponse
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
        userDefaults.set(smartAlertsEnabled, forKey: "herdr.smartAlerts")
    }

    func prepareSmartAlerts() async {
        guard smartAlertsEnabled, hasCompletedSetup, !isDemoMode else { return }
        let granted = await NotificationManager.requestAuthorization()
        smartAlertsEnabled = granted
        userDefaults.set(granted, forKey: "herdr.smartAlerts")
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
        noteUserInteraction()
        guard !paneID.isEmpty else { return }
        let pendingRoute = PendingPaneRoute(paneID: paneID, order: nextPendingPaneRouteOrder())
        // A sidebar click, notification, or deep link is a newer explicit user
        // choice and must not be stolen later by an outstanding quick session.
        pendingPaneRoutes.removeAll(keepingCapacity: true)
        guard let pane = pane(id: paneID) ?? resolveRawPane(id: paneID) else {
            pendingPaneRoutes[.direct] = pendingRoute
            return
        }
        route(to: pane)
    }

    /// Resolves a pane the same way `openPane(id:)` does for an already-scoped
    /// id, but starting from a *raw* (unscoped) pane id plus an optional
    /// machine id — the shape the JS board bridge and the legacy Active Work
    /// tracked-session cards both hand back. An empty-string machine id (the
    /// JS side's "no machine" convention) is treated the same as `nil`.
    func openPane(rawPaneID: String, machineID: String?) {
        let normalizedMachineID = (machineID?.isEmpty == false) ? machineID : nil
        let resolved: HerdrPane?
        if let normalizedMachineID {
            resolved = pane(id: MachineScopedID.compose(machineID: normalizedMachineID, rawID: rawPaneID))
        } else {
            resolved = resolveRawPane(id: rawPaneID)
        }
        guard let resolved else {
            toastMessage = "That pane is no longer available in the connected fleet"
            return
        }
        openPane(id: resolved.id)
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Acknowledges a pane when this client knows about an unread alert, or
    /// once per stale-`.done` episode, when its done status may be a stale
    /// server projection. The mounted session's tap gesture calls this on
    /// every interaction, so neither idle/working panes with nothing unread
    /// nor a repeat tap within the same done episode may POST.
    func acknowledgeUnreadAlerts(for pane: HerdrPane) {
        let hadUnread = markPaneAlertsReadLocally(pane.id)
        let shouldAcknowledgeRemotely: Bool
        if hadUnread {
            shouldAcknowledgeRemotely = true
        } else if pane.agentStatus == .done {
            let episodeKey = pane.episodeKey
            shouldAcknowledgeRemotely = lastAckedDoneEpisodeByPaneID[pane.id] != episodeKey
            if shouldAcknowledgeRemotely {
                lastAckedDoneEpisodeByPaneID[pane.id] = episodeKey
            }
        } else {
            shouldAcknowledgeRemotely = false
        }
        guard shouldAcknowledgeRemotely else { return }
        noteUserInteraction(machineID: pane.machineID)
        markPaneAlertsReadRemotely(pane)
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

    /// GitHub's option-click-a-chevron gesture, ported to the navigator: the row
    /// you clicked decides the direction and every visible workspace follows it.
    /// The clicked row always lands where a plain click would have put it —
    /// Option only widens the blast radius.
    func toggleSidebarSection(_ workspaceID: String, applyingToAll ids: some Sequence<String>) {
        setSidebarWorkspacesExpanded(
            collapsedSidebarWorkspaceIDs.contains(workspaceID),
            ids: Array(ids) + [workspaceID]
        )
    }

    /// Bulk counterpart to `toggleSidebarSection(_:)`. Pure with respect to the
    /// view — the caller decides which workspaces are in scope, so a unit test can
    /// exercise the whole gesture without a sidebar.
    func setSidebarWorkspacesExpanded(_ expanded: Bool, ids: some Sequence<String>) {
        let scope = Set(ids)
        guard !scope.isEmpty else { return }
        let updated = expanded
            ? collapsedSidebarWorkspaceIDs.subtracting(scope)
            : collapsedSidebarWorkspaceIDs.union(scope)
        guard updated != collapsedSidebarWorkspaceIDs else { return }
        collapsedSidebarWorkspaceIDs = updated
        userDefaults.set(Array(collapsedSidebarWorkspaceIDs), forKey: "herdr.sidebar.collapsedWorkspaces")
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

    func toggleSidebarTabSection(_ tabID: String, applyingToAll ids: some Sequence<String>) {
        setSidebarTabsExpanded(collapsedSidebarTabIDs.contains(tabID), ids: Array(ids) + [tabID])
    }

    func setSidebarTabsExpanded(_ expanded: Bool, ids: some Sequence<String>) {
        let scope = Set(ids)
        guard !scope.isEmpty else { return }
        let updated = expanded
            ? collapsedSidebarTabIDs.subtracting(scope)
            : collapsedSidebarTabIDs.union(scope)
        guard updated != collapsedSidebarTabIDs else { return }
        collapsedSidebarTabIDs = updated
        userDefaults.set(Array(collapsedSidebarTabIDs), forKey: "herdr.sidebar.collapsedTabs")
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

    /// Navigate ▸ Reveal in Sidebar (⇧⌘K).
    @discardableResult
    func revealSelectedPaneInSidebar() -> Bool {
        guard let selectedPaneID else { return false }
        return revealPaneInSidebar(id: selectedPaneID)
    }

    /// Makes the navigator show `paneID`'s row: undoes any scope or recency
    /// filter that excludes it, expands its machine, workspace, and tab, and
    /// publishes a token the sidebar turns into a `scrollTo`.
    ///
    /// Expanding the ancestors is not always what surfaces the row — an unread,
    /// starred, or stale chat is promoted to its own section and is not under its
    /// workspace at all (`SidebarTree.buildEntry`). Both placements draw the same
    /// `chatRow`, so the single scroll target covers them.
    ///
    /// Returns `false` when the pane is not in the connected fleet, so the caller
    /// can leave the sidebar alone.
    @discardableResult
    func revealPaneInSidebar(id paneID: String) -> Bool {
        guard let pane = pane(id: paneID) else { return false }

        // A machine scope pinned to some other host filters the pane's workspace
        // out entirely. Narrow to the pane's own machine rather than widening to
        // `.all`, which would add machine chrome the user did not ask for.
        if case let .machine(scopedID) = machineScope, scopedID != pane.machineID {
            setMachineScope(.machine(pane.machineID))
        }

        // `.all` is the only recency that is guaranteed to include the pane,
        // whatever its timestamps say.
        if !sidebarRecency.includes(pane, now: Date(), calendar: .autoupdatingCurrent) {
            sidebarRecency = .all
        }

        expandSidebarAncestors(of: pane)

        sidebarRevealPaneID = pane.id
        sidebarRevealToken &+= 1
        return true
    }

    private func expandSidebarAncestors(of pane: HerdrPane) {
        if collapsedSidebarMachineIDs.remove(pane.machineID) != nil {
            userDefaults.set(Array(collapsedSidebarMachineIDs), forKey: "herdr.sidebar.collapsedMachines")
        }
        if let workspace = workspace(containing: pane),
           collapsedSidebarWorkspaceIDs.remove(workspace.id) != nil {
            userDefaults.set(Array(collapsedSidebarWorkspaceIDs), forKey: "herdr.sidebar.collapsedWorkspaces")
        }
        if collapsedSidebarTabIDs.remove(pane.scopedTabID) != nil {
            userDefaults.set(Array(collapsedSidebarTabIDs), forKey: "herdr.sidebar.collapsedTabs")
        }
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

    func toggleMutedHudSession(_ paneID: String) {
        if mutedHudSessionIDs.contains(paneID) {
            mutedHudSessionIDs.remove(paneID)
        } else {
            mutedHudSessionIDs.insert(paneID)
        }
        userDefaults.set(Array(mutedHudSessionIDs), forKey: "herdr.hud.mutedSessions")
    }

    func composerDraft(for paneID: String) -> String {
        composerDrafts[paneID] ?? ""
    }

    func setComposerDraft(_ text: String, for paneID: String) {
        // Blank drafts are dropped rather than stored, so clicking through
        // panes costs nothing and the dictionary only holds real work.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if composerDrafts.removeValue(forKey: paneID) != nil { return }
            return
        }
        guard composerDrafts[paneID] != text else { return }
        composerDrafts[paneID] = text
    }

    func notePaneDetailMode(_ mode: PaneDetailMode, gitIsAvailable: Bool, for paneID: String) {
        currentPaneDetailModeOwner = paneID
        // Observation notifies on write, not change, and the always-mounted
        // toolbar observes both — only assign when something actually moved.
        if currentPaneDetailMode != mode { currentPaneDetailMode = mode }
        if currentPaneGitIsAvailable != gitIsAvailable { currentPaneGitIsAvailable = gitIsAvailable }
    }

    /// Only the pane that published the mode may retract it. Switching panes
    /// mounts the replacement before the outgoing view disappears, so an
    /// unconditional clear would wipe the value the new pane just wrote.
    func clearPaneDetailMode(for paneID: String) {
        guard currentPaneDetailModeOwner == paneID else { return }
        currentPaneDetailModeOwner = nil
        currentPaneDetailMode = nil
        currentPaneGitIsAvailable = false
    }

    func dismissHudChip(_ paneID: String) {
        guard let pane = pane(id: paneID) else { return }
        dismissedHudChips[paneID] = HudChipDismissal(pane: pane, dismissedAt: Date())
        persistDismissedHudChips()
    }

    private func persistDismissedHudChips() {
        dismissedHudChips = HerdrHudSessionChips.capped(
            dismissedHudChips,
            limit: Self.maxPersistedHudChipDismissals
        )
        userDefaults.set(
            try? JSONEncoder().encode(dismissedHudChips),
            forKey: Self.dismissedHudChipsKey
        )
    }

    private static let dismissedHudChipsKey = "herdr.hud.dismissedChips.v1"
    private static let maxPersistedHudChipDismissals = 500

    /// Total: a missing key or unreadable payload yields an empty map rather
    /// than throwing. A lost dismissal only re-shows a chip; a crash at launch
    /// would be far worse.
    private static func loadDismissedHudChips(defaults: UserDefaults) -> [String: HudChipDismissal] {
        guard let data = defaults.data(forKey: dismissedHudChipsKey),
              let stored = try? JSONDecoder().decode([String: HudChipDismissal].self, from: data)
        else { return [:] }
        return HerdrHudSessionChips.capped(stored, limit: maxPersistedHudChipDismissals)
    }

    func openWorkspace(id: String) {
        noteUserInteraction()
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

    @discardableResult
    func refreshResultArtifacts(machineID: String) async throws -> [AgentResultArtifact] {
        if isDemoMode {
            return resultArtifacts.filter { $0.machineID == machineID }
        }
        guard let client = client(forMachine: machineID) else {
            throw APIError.noActiveConnection(machineID: machineID)
        }
        return try await refreshResultArtifacts(
            machineID: machineID,
            using: client,
            expectedGeneration: connectionGeneration
        )
    }

    func openResultArtifact(_ artifact: AgentResultArtifact) async {
        let presentationID = artifact.id
        switch resultArtifactPhase(id: presentationID) {
        case .opening, .downloading:
            return
        case .available, .opened, .failed:
            break
        }
        recentlyOpenedResultArtifactIDs.remove(presentationID)
        resultArtifactRetirementTasks[presentationID]?.cancel()
        resultArtifactRetirementTasks[presentationID] = nil
        resultArtifactPhases[presentationID] = artifact.kind == .file ? .downloading : .opening

        do {
            let sourceClient = client(forMachine: artifact.machineID)
            if let resultArtifactOpenOverride {
                try await resultArtifactOpenOverride(artifact, sourceClient)
            } else {
                switch artifact.kind {
                case .link:
                    try await resultArtifactOpener.open(artifact)
                case .file:
                    guard let sourceClient else {
                        throw APIError.noActiveConnection(machineID: artifact.machineID)
                    }
                    try await resultArtifactOpener.open(
                        artifact,
                        downloadFile: { destinationURL in
                            try await sourceClient.downloadResultArtifactContent(
                                id: artifact.rawID,
                                expectedByteSize: artifact.byteSize ?? -1,
                                to: destinationURL
                            )
                        }
                    )
                }
            }
            resultArtifactPhases[presentationID] = .opened
            recentlyOpenedResultArtifactIDs.insert(presentationID)
            resultArtifactRetirementTasks[presentationID] = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(650)) }
                catch { return }
                guard !Task.isCancelled else { return }
                self?.recentlyOpenedResultArtifactIDs.remove(presentationID)
                self?.resultArtifactRetirementTasks[presentationID] = nil
            }
        } catch {
            resultArtifactPhases[presentationID] = .failed(error.localizedDescription)
        }
    }

    /// Removes an unwanted result without launching it. The durable handled
    /// ledger prevents a canonical refresh or app restart from resurfacing it.
    func dismissResultArtifact(_ artifact: AgentResultArtifact) {
        let presentationID = artifact.id
        switch resultArtifactPhase(id: presentationID) {
        case .available, .failed:
            break
        case .opening, .downloading, .opened:
            return
        }
        resultArtifactRetirementTasks[presentationID]?.cancel()
        resultArtifactRetirementTasks[presentationID] = nil
        recentlyOpenedResultArtifactIDs.remove(presentationID)
        resultArtifactOpenedLedger.markOpened(presentationID)
        resultArtifactPhases[presentationID] = .opened
    }

    /// Internal visibility is intentional: focused tests exercise fleet-wide
    /// deduping without needing to manufacture a complete connection loop.
    func ingestResultArtifacts(
        _ artifacts: [AgentResultArtifact],
        machineID: String,
        replacingMachineSlice: Bool
    ) {
        var seenRawIDs: Set<String> = []
        var stamped: [AgentResultArtifact] = []
        stamped.reserveCapacity(artifacts.count)
        for artifact in artifacts where seenRawIDs.insert(artifact.rawID).inserted {
            stamped.append(artifact.stamped(machineID: machineID))
        }

        var merged = resultArtifacts
        if replacingMachineSlice {
            let insertionIndex = merged.firstIndex(where: { $0.machineID == machineID }) ?? merged.endIndex
            merged.removeAll { $0.machineID == machineID }
            merged.insert(contentsOf: stamped, at: min(insertionIndex, merged.endIndex))
        } else {
            for artifact in stamped.reversed() {
                merged.removeAll { $0.id == artifact.id }
                merged.insert(artifact, at: 0)
            }
        }

        if merged != resultArtifacts { resultArtifacts = merged }
        let validIDs = Set(merged.map(\.id))
        var phases = resultArtifactPhases.filter { validIDs.contains($0.key) }
        for artifact in merged where phases[artifact.id] == nil {
            phases[artifact.id] = resultArtifactOpenedLedger.contains(artifact.id) ? .opened : .available
        }
        if phases != resultArtifactPhases { resultArtifactPhases = phases }
    }

    /// Captures the event clock at the exact point a canonical list request is
    /// launched. The request revision also prevents an older overlapping
    /// response from applying after a newer request has started.
    func beginResultArtifactListRequest(machineID: String) -> ResultArtifactListRequest {
        var state = resultArtifactReconciliation[machineID] ?? ResultArtifactReconciliationState()
        state.latestListRequestRevision &+= 1
        let request = ResultArtifactListRequest(
            machineID: machineID,
            requestRevision: state.latestListRequestRevision,
            eventBaseline: state.latestEventRevision
        )
        resultArtifactReconciliation[machineID] = state
        return request
    }

    /// Records an SSE presentation before publishing it to observable state.
    /// Its revision lets a stale in-flight list response identify the result as
    /// newer than that response's request baseline.
    func ingestResultArtifactEvent(_ artifact: AgentResultArtifact, machineID: String) {
        let presentationID = MachineScopedID.compose(machineID: machineID, rawID: artifact.rawID)
        var state = resultArtifactReconciliation[machineID] ?? ResultArtifactReconciliationState()
        state.latestEventRevision &+= 1
        state.eventRevisionByArtifactID[presentationID] = state.latestEventRevision
        resultArtifactReconciliation[machineID] = state
        ingestResultArtifacts(
            [artifact],
            machineID: machineID,
            replacingMachineSlice: false
        )
    }

    /// Applies a canonical server list while retaining any SSE artifacts that
    /// arrived after this request began. A subsequent list starts at the newer
    /// event baseline, so it can authoritatively prune a result that is absent.
    @discardableResult
    func reconcileResultArtifactList(
        _ artifacts: [AgentResultArtifact],
        machineID: String,
        request: ResultArtifactListRequest
    ) -> Bool {
        guard request.machineID == machineID,
              var state = resultArtifactReconciliation[machineID],
              request.requestRevision == state.latestListRequestRevision
        else { return false }

        let canonicalIDs = Set(artifacts.map {
            MachineScopedID.compose(machineID: machineID, rawID: $0.rawID)
        })
        let lateEvents = resultArtifacts.filter { artifact in
            artifact.machineID == machineID
                && !canonicalIDs.contains(artifact.id)
                && (state.eventRevisionByArtifactID[artifact.id] ?? 0) > request.eventBaseline
        }
        ingestResultArtifacts(
            lateEvents + artifacts,
            machineID: machineID,
            replacingMachineSlice: true
        )

        let retainedIDs = Set(resultArtifacts.lazy.filter { $0.machineID == machineID }.map(\.id))
        resultArtifactOpenedLedger.reconcile(
            machineID: machineID,
            activePresentationIDs: retainedIDs
        )
        state.eventRevisionByArtifactID = state.eventRevisionByArtifactID.filter { presentationID, revision in
            revision > request.eventBaseline && retainedIDs.contains(presentationID)
        }
        resultArtifactReconciliation[machineID] = state
        return true
    }

    private func refreshResultArtifacts(
        machineID: String,
        using client: HerdrAPIClient,
        expectedGeneration: Int
    ) async throws -> [AgentResultArtifact] {
        let listRequest = beginResultArtifactListRequest(machineID: machineID)
        let response = try await client.fetchResultArtifacts()
        guard response.ok else { throw APIError.invalidResponse }
        guard expectedGeneration == connectionGeneration else { throw CancellationError() }
        reconcileResultArtifactList(
            response.artifacts,
            machineID: machineID,
            request: listRequest
        )
        return resultArtifacts.filter { $0.machineID == machineID }
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
        var previousAlertIDs: Set<String> = []
        var previousReadAlertIDs: Set<String> = []
        for alert in alerts where alert.machineID == machineID {
            previousAlertIDs.insert(alert.id)
            if alert.isRead { previousReadAlertIDs.insert(alert.id) }
        }
        var freshWorkspaces: [HerdrWorkspace] = []
        for workspace in response.workspaces {
            freshWorkspaces.append(workspace.stamped(machineID: machineID))
        }
        var freshAlerts: [HerdrAlert] = []
        for alert in response.alerts {
            freshAlerts.append(alert.stamped(machineID: machineID))
        }
        let previousWorkspaces = workspaces
        let mergedWorkspaces = mergeWorkspaces(
            current: previousWorkspaces,
            fresh: freshWorkspaces,
            machineID: machineID
        )
        let mergedAlerts = mergeAlerts(current: alerts, fresh: freshAlerts, machineID: machineID)
        let workspacesChanged = mergedWorkspaces != workspaces
        let alertsChanged = mergedAlerts != alerts
        let contentChanged = workspacesChanged || alertsChanged
        let wasBoring = isBoringRefresh(
            previousWorkspaces: previousWorkspaces,
            freshWorkspaces: freshWorkspaces,
            machineID: machineID,
            contentChanged: contentChanged,
            alertsChanged: alertsChanged
        )
        if workspacesChanged { workspaces = mergedWorkspaces }
        if alertsChanged { alerts = mergedAlerts }
        if contentChanged {
            lastUpdated = .now
            if !wasBoring { fleetRevision &+= 1 }
        }
        lastSyncedAt = .now
        if errorMessage != nil { errorMessage = nil }
        if lastPresentedConnectionError != nil { lastPresentedConnectionError = nil }
        if contentChanged || starredChatsWouldChange(
            machineID: machineID,
            serverStarredRawIDs: response.starredPaneIDs
        ) {
            reconcileStarredChats(machineID: machineID, serverStarredRawIDs: response.starredPaneIDs)
        }
        recordRefreshResult(machineID: machineID, wasBoring: wasBoring)
        refreshTick &+= 1
        var currentAlertIDs: Set<String> = []
        var readAlertIDs: Set<String> = []
        for alert in freshAlerts {
            currentAlertIDs.insert(alert.id)
            if alert.isRead { readAlertIDs.insert(alert.id) }
        }
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
        do {
            _ = try await refreshResultArtifacts(
                machineID: machineID,
                using: client,
                expectedGeneration: expectedGeneration
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Result presentation is additive. A mixed-version server must not
            // take the core fleet connection offline while it rolls forward.
        }
        updateBadgeIfNeeded()
    }

    func noteUserInteraction(machineID: String? = nil) {
        if let machineID {
            resetFleetRefreshBackoff(for: machineID)
            return
        }
        var machineIDs: [String] = []
        for machine in machines { machineIDs.append(machine.id) }
        for machineID in runtimes.keys where !machineIDs.contains(machineID) {
            machineIDs.append(machineID)
        }
        for machineID in machineIDs {
            resetFleetRefreshBackoff(for: machineID)
        }
    }

    func currentFleetRefreshWindow(forMachine machineID: String) -> Duration {
        let boringCycles = runtimes[machineID]?.consecutiveBoringRefreshes ?? 0
        return boringCycles >= fleetRefreshBoringCycleThreshold
            ? fleetRefreshBackoffWindow
            : fleetRefreshBaseWindow
    }

    private func mergeWorkspaces(
        current: [HerdrWorkspace],
        fresh: [HerdrWorkspace],
        machineID: String
    ) -> [HerdrWorkspace] {
        var merged: [HerdrWorkspace] = []
        merged.reserveCapacity(current.count + fresh.count)
        var didInsertMachineSlice = false
        for workspace in current {
            guard workspace.machineID == machineID else {
                merged.append(workspace)
                continue
            }
            guard !didInsertMachineSlice else { continue }
            didInsertMachineSlice = true
            merged.append(contentsOf: fresh)
        }
        if !didInsertMachineSlice {
            merged.append(contentsOf: fresh)
        }
        return merged
    }

    private func mergeAlerts(
        current: [HerdrAlert],
        fresh: [HerdrAlert],
        machineID: String
    ) -> [HerdrAlert] {
        let reconciled: [HerdrAlert]
        if pendingReadAcknowledgements.isEmpty {
            reconciled = fresh
        } else {
            reconciled = fresh.map { alert in
                guard !alert.isRead,
                      pendingReadAcknowledgements.contains(alert.scopedPaneID)
                else { return alert }
                return Self.markedRead(alert)
            }
        }
        var merged: [HerdrAlert] = []
        merged.reserveCapacity(current.count + reconciled.count)
        var didInsertMachineSlice = false
        for alert in current {
            guard alert.machineID == machineID else {
                merged.append(alert)
                continue
            }
            guard !didInsertMachineSlice else { continue }
            didInsertMachineSlice = true
            merged.append(contentsOf: reconciled)
        }
        if !didInsertMachineSlice {
            merged.append(contentsOf: reconciled)
        }
        return merged
    }

    private func isBoringRefresh(
        previousWorkspaces: [HerdrWorkspace],
        freshWorkspaces: [HerdrWorkspace],
        machineID: String,
        contentChanged: Bool,
        alertsChanged: Bool
    ) -> Bool {
        guard contentChanged else { return true }
        guard !alertsChanged else { return false }

        var previousByWorkspaceID: [String: HerdrWorkspace] = [:]
        var previousCount = 0
        for workspace in previousWorkspaces where workspace.machineID == machineID {
            previousByWorkspaceID[workspace.workspaceID] = workspace
            previousCount += 1
        }
        guard previousCount == freshWorkspaces.count else { return false }
        for workspace in freshWorkspaces {
            guard let previous = previousByWorkspaceID[workspace.workspaceID],
                  previous.isEqualIgnoringPaneRevisions(to: workspace)
            else { return false }
        }
        return true
    }

    private func starredChatsWouldChange(machineID: String, serverStarredRawIDs: [String]?) -> Bool {
        guard let serverStarredRawIDs else { return false }
        var merged: Set<String> = []
        for paneID in starredChatIDs {
            if MachineScopedID.split(paneID)?.machineID != machineID {
                merged.insert(paneID)
            }
        }
        for rawID in serverStarredRawIDs {
            merged.insert(MachineScopedID.compose(machineID: machineID, rawID: rawID))
        }
        return merged != starredChatIDs
    }

    private func recordRefreshResult(machineID: String, wasBoring: Bool) {
        var runtime = runtimes[machineID] ?? MachineRuntime()
        if wasBoring {
            runtime.consecutiveBoringRefreshes += 1
        } else {
            runtime.consecutiveBoringRefreshes = 0
        }
        runtimes[machineID] = runtime
    }

    private func resetFleetRefreshBackoff(for machineID: String) {
        var runtime = runtimes[machineID] ?? MachineRuntime()
        runtime.consecutiveBoringRefreshes = 0
        runtimes[machineID] = runtime
    }

    private func rebuildPaneIndex() {
        var rebuilt: [String: PaneLocation] = [:]
        for workspaceIndex in workspaces.indices {
            let panes = workspaces[workspaceIndex].panes
            for paneIndex in panes.indices {
                rebuilt[panes[paneIndex].id] = PaneLocation(
                    workspaceIndex: workspaceIndex,
                    paneIndex: paneIndex
                )
            }
        }
        paneIndex = rebuilt
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
        noteUserInteraction(machineID: machineID)
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
        #if DEBUG
        if HerdrPiReplay.shared != nil {
            workspaces = workspaces.map { workspace in
                var copy = workspace
                copy.panes = workspace.panes.map { pane in
                    pane.machineID == HerdrPiReplay.machineID && pane.paneID == HerdrPiReplay.paneRawID
                        ? HerdrPiReplay.piCapable(pane).stamped(machineID: HerdrPiReplay.machineID)
                        : pane
                }
                return copy
            }
        }
        #endif
        alerts = DemoData.alerts.map { $0.stamped(machineID: "demo1") }
        activityHistoryAlerts = alerts
        activityFeedError = nil
        fleetRevision &+= 1
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
        #if DEBUG
        if HerdrPiReplay.shared != nil {
            selectedWorkspaceID = "\(HerdrPiReplay.machineID)|w1"
            selectedPaneID = "\(HerdrPiReplay.machineID)|\(HerdrPiReplay.paneRawID)"
        }
        #endif
    }

    private func resetConnectionState() {
        cancelDeferredRefreshes()
        for task in resultArtifactRetirementTasks.values { task.cancel() }
        resultArtifactRetirementTasks = [:]
        resultArtifactReconciliation = [:]
        runtimes = [:]
        machineStates = [:]
        activeServerConnection = nil
        connectionState = .disconnected
        let hadFleetContent = !workspaces.isEmpty || !alerts.isEmpty
        workspaces = []
        alerts = []
        resultArtifacts = []
        resultArtifactPhases = [:]
        recentlyOpenedResultArtifactIDs = []
        activityHistoryAlerts = []
        activityFeedError = nil
        isRefreshingActivity = false
        if hadFleetContent { fleetRevision &+= 1 }
        selectedWorkspaceID = nil
        selectedPaneID = nil
        workspacePath = []
        isSidebarPresented = false
        lastUpdated = nil
        lastSyncedAt = nil
        isRefreshing = false
        isSending = false
        quickPiSessionMachineIDs = []
        discardPendingQuickPaneRoutes()
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
        // A refresh that returned nothing is more likely a half-failed poll than
        // a machine with no panes, and dropping drafts is unrecoverable — so
        // only prune when this machine actually reported panes. Chip dismissals
        // need the same guard for the same reason: `prunedDismissals` drops any
        // entry whose pane is absent, so an empty poll would un-dismiss every
        // chip the user had cleared.
        if !validPaneIDs.isEmpty {
            let prunedDrafts = composerDrafts.filter { paneID, _ in
                guard MachineScopedID.split(paneID)?.machineID == machineID else { return true }
                return validPaneIDs.contains(paneID)
            }
            if prunedDrafts != composerDrafts { composerDrafts = prunedDrafts }
            let prunedDoneEpisodes = lastAckedDoneEpisodeByPaneID.filter { paneID, _ in
                guard MachineScopedID.split(paneID)?.machineID == machineID else { return true }
                return validPaneIDs.contains(paneID)
            }
            if prunedDoneEpisodes != lastAckedDoneEpisodeByPaneID {
                lastAckedDoneEpisodeByPaneID = prunedDoneEpisodes
            }
            let prunedChipDismissals = HerdrHudSessionChips.prunedDismissals(
                dismissedHudChips,
                machineID: machineID,
                panes: freshWorkspaces.flatMap(\.panes)
            )
            // Observation notifies on write, not change. The always-mounted HUD's SwiftUI root is
            // the sole observer, so assigning an equal value on every refresh invalidates it.
            if prunedChipDismissals != dismissedHudChips {
                dismissedHudChips = prunedChipDismissals
                persistDismissedHudChips()
            }
        }
    }

    private func beginQuickPaneRoute(
        machineID: String,
        requestID: String
    ) -> PendingPaneRouteKey {
        let key = PendingPaneRouteKey.quick(machineID: machineID, requestID: requestID)
        pendingPaneRoutes[key] = PendingPaneRoute(
            paneID: nil,
            order: nextPendingPaneRouteOrder()
        )
        return key
    }

    private func completeQuickPaneRoute(_ key: PendingPaneRouteKey, paneID: String) {
        guard var pendingRoute = pendingPaneRoutes[key] else { return }
        pendingRoute.paneID = paneID
        pendingPaneRoutes[key] = pendingRoute
        resolvePendingPaneRoute()
    }

    private func cancelPendingPaneRoute(_ key: PendingPaneRouteKey) {
        guard pendingPaneRoutes.removeValue(forKey: key) != nil else { return }
        resolvePendingPaneRoute()
    }

    private func discardPendingQuickPaneRoutes() {
        let directRoute = pendingPaneRoutes[.direct]
        pendingPaneRoutes.removeAll(keepingCapacity: true)
        if let directRoute { pendingPaneRoutes[.direct] = directRoute }
    }

    private func nextPendingPaneRouteOrder() -> UInt64 {
        nextPaneRouteOrder &+= 1
        return nextPaneRouteOrder
    }

    private func resolvePendingPaneRoute() {
        guard let pendingRoute = pendingPaneRoutes.values.max(by: { $0.order < $1.order }),
              let pendingPaneID = pendingRoute.paneID,
              let pane = pane(id: pendingPaneID) ?? resolveRawPane(id: pendingPaneID)
        else { return }
        pendingPaneRoutes.removeAll(keepingCapacity: true)
        route(to: pane)
    }

    private func route(to pane: HerdrPane) {
        isSidebarPresented = false
        selectedTab = .workspaces
        selectedWorkspaceID = workspace(containing: pane)?.id
        selectedPaneID = pane.id
        workspacePath = selectedWorkspaceID.map { [.workspace($0), .pane(pane.id)] } ?? [.pane(pane.id)]

        // Routing remains unconditional on the server. Besides clearing known
        // alerts, the endpoint acknowledges a stale done-state projection even
        // when this client has not fetched the matching alert yet.
        _ = markPaneAlertsReadLocally(pane.id)
        markPaneAlertsReadRemotely(pane)
    }

    @discardableResult
    private func markPaneAlertsReadLocally(_ paneID: String) -> Bool {
        let newlyReadAlertIDs = Set(
            alerts.lazy
                .filter { $0.scopedPaneID == paneID && !$0.isRead }
                .map(\.id)
        )
        guard !newlyReadAlertIDs.isEmpty else {
            return false
        }

        alerts = alerts.map { alert in
            guard alert.scopedPaneID == paneID, !alert.isRead else { return alert }
            return Self.markedRead(alert)
        }
        updateBadgeIfNeeded()
        // Withdraw immediately for the optimistic local read: the banner should
        // disappear the instant the user reads the pane. If the pending POST later
        // fails permanently and a refresh restores the server's unread alert, do
        // not re-post the banner. That policy is intentional.
        Task { await NotificationManager.removeDelivered(alertIDs: newlyReadAlertIDs) }
        return true
    }

    private static func markedRead(_ alert: HerdrAlert) -> HerdrAlert {
        HerdrAlert(
            id: alert.rawID,
            workspaceID: alert.workspaceID,
            paneID: alert.paneID,
            status: alert.status,
            title: alert.title,
            message: alert.message,
            createdAt: alert.createdAt,
            isRead: true
        ).stamped(machineID: alert.machineID)
    }


    private func markPaneAlertsReadRemotely(_ pane: HerdrPane) {
        guard !isDemoMode else { return }
        guard let client = client(forMachine: pane.machineID) else {
            // No client is connected for this machine right now. Queue the ack
            // instead of dropping it. It is replayed once this machine's
            // connection reaches `.live` again, see `setRuntimeState` and
            // `drainPendingRemoteReadAcknowledgements` below. Demo mode never
            // reaches here (guarded above), so it stays a pure no-op as before.
            pendingRemoteReadAcknowledgements.insert(pane.id)
            return
        }
        performMarkPaneAlertsReadRemotely(pane, client: client)
    }

    private func performMarkPaneAlertsReadRemotely(_ pane: HerdrPane, client: HerdrAPIClient) {
        let scopedPaneID = pane.id
        // Hold the optimistic local read until the server confirms it. A refresh
        // landing before this POST would otherwise restore the server's unread
        // copy and relight a pane the user just cleared.
        pendingReadAcknowledgements.insert(scopedPaneID)
        Task { [weak self] in
            for attempt in 1...Self.paneAlertReadAttempts {
                do {
                    try await client.markPaneAlertsRead(paneID: pane.paneID)
                    break
                } catch {
                    if attempt == Self.paneAlertReadAttempts {
                        Self.alertsLogger.error(
                            "failed to mark pane \(pane.paneID, privacy: .public) alerts read: \(error.localizedDescription, privacy: .public)"
                        )
                    } else {
                        try? await Task.sleep(for: Self.paneAlertReadRetryDelay)
                    }
                }
            }
            // Releasing the hold after a permanent failure lets the next refresh
            // show the server's truth instead of a read state it never received.
            self?.pendingReadAcknowledgements.remove(scopedPaneID)
        }
    }

    private func drainPendingRemoteReadAcknowledgements(machineID: String) {
        guard !pendingRemoteReadAcknowledgements.isEmpty,
              let client = client(forMachine: machineID)
        else { return }
        let scopedIDs = pendingRemoteReadAcknowledgements.filter {
            MachineScopedID.split($0)?.machineID == machineID
        }
        guard !scopedIDs.isEmpty else { return }
        pendingRemoteReadAcknowledgements.subtract(scopedIDs)
        for scopedID in scopedIDs {
            guard let pane = pane(id: scopedID) else { continue }
            performMarkPaneAlertsReadRemotely(pane, client: client)
        }
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

    private func handleResultArtifactCreated(
        _ event: HerdrEvent,
        machineID: String,
        using client: HerdrAPIClient,
        expectedGeneration: Int
    ) async {
        if let artifact = AgentResultArtifact(eventData: event.data) {
            ingestResultArtifactEvent(artifact, machineID: machineID)
            return
        }

        // If a future server enriches or wraps the event differently, recover
        // through the canonical endpoint rather than silently losing a result.
        _ = try? await refreshResultArtifacts(
            machineID: machineID,
            using: client,
            expectedGeneration: expectedGeneration
        )
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
        resultArtifactReconciliation[id] = nil
        let removedArtifactIDs = Set(resultArtifacts.lazy.filter { $0.machineID == id }.map(\.id))
        resultArtifactOpenedLedger.reconcile(machineID: id, activePresentationIDs: [])
        for artifactID in removedArtifactIDs {
            resultArtifactRetirementTasks[artifactID]?.cancel()
            resultArtifactRetirementTasks[artifactID] = nil
        }
        machines.removeAll { $0.id == id }
        if !isDemoMode {
            persistMachines()
            KeychainStore.removeValue(for: "api-token.\(id)")
        }
        runtimes[id] = nil
        machineStates[id] = nil
        let workspaceCount = workspaces.count
        let alertCount = alerts.count
        workspaces.removeAll { $0.machineID == id }
        alerts.removeAll { $0.machineID == id }
        resultArtifacts.removeAll { $0.machineID == id }
        resultArtifactPhases = resultArtifactPhases.filter { !removedArtifactIDs.contains($0.key) }
        recentlyOpenedResultArtifactIDs.subtract(removedArtifactIDs)
        activityHistoryAlerts.removeAll { $0.machineID == id }
        if workspaces.count != workspaceCount || alerts.count != alertCount {
            fleetRevision &+= 1
        }
        starredChatIDs = starredChatIDs.filter { MachineScopedID.split($0)?.machineID != id }
        mutedHudSessionIDs = mutedHudSessionIDs.filter { MachineScopedID.split($0)?.machineID != id }
        dismissedHudChips = dismissedHudChips.filter {
            MachineScopedID.split($0.key)?.machineID != id
        }
        persistDismissedHudChips()
        composerDrafts = composerDrafts.filter {
            MachineScopedID.split($0.key)?.machineID != id
        }
        lastAckedDoneEpisodeByPaneID = lastAckedDoneEpisodeByPaneID.filter {
            MachineScopedID.split($0.key)?.machineID != id
        }
        collapsedSidebarWorkspaceIDs = collapsedSidebarWorkspaceIDs.filter { MachineScopedID.split($0)?.machineID != id }
        collapsedSidebarTabIDs = collapsedSidebarTabIDs.filter { MachineScopedID.split($0)?.machineID != id }
        pendingRemoteReadAcknowledgements = pendingRemoteReadAcknowledgements.filter {
            MachineScopedID.split($0)?.machineID != id
        }
        collapsedSidebarMachineIDs.remove(id)
        userDefaults.set(Array(starredChatIDs), forKey: "herdr.sidebar.starredChats")
        userDefaults.set(Array(mutedHudSessionIDs), forKey: "herdr.hud.mutedSessions")
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
        // The synthetic UI-test machine is intentionally ephemeral and never
        // writes its launch token to Keychain. Preserve the configuration that
        // init created from -HerdrUITestAPIToken when the connection driver
        // rebuilds its runtime. Real machines continue to read the latest
        // credential from Keychain after edits or reconnects.
        let token = machine.id == "ui-test"
            ? runtimes[machine.id]?.connection?.configuration.token ?? ""
            : KeychainStore.value(for: "api-token.\(machine.id)")
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
                    if event.event == "ready" {
                        seedLastEventIDFromReady(event, for: machine.id)
                        do {
                            try await refreshResultArtifactsAfterEventStreamReady(
                                machineID: machine.id,
                                using: client,
                                expectedGeneration: expectedGeneration
                            )
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            // Older servers do not expose result artifacts. The
                            // stream and core fleet connection remain usable.
                        }
                    }
                    recordLastEventID(event.id, for: machine.id)
                    if event.event == "stream.reset", streamResetIsBackendRestart(event) {
                        resetLastEventID(for: machine.id)
                    }
                    if event.event == "result_artifact.created" {
                        await handleResultArtifactCreated(
                            event,
                            machineID: machine.id,
                            using: client,
                            expectedGeneration: expectedGeneration
                        )
                    } else if event.event == "active_work.updated" {
                        activeWorkRefreshTick &+= 1
                    } else if event.event == "snapshot.updated" || event.event == "alert.created" ||
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
              case .bool(true)? = values["synthetic"],
              let completed = runtimes[machineID]?.lastRefreshCompletedAt
        else { return false }
        return completed.duration(to: ContinuousClock().now) < .seconds(2)
    }

    /// Closes the list-to-stream subscription gap for a fresh connection. The
    /// server intentionally starts a cursorless SSE client at its newest event,
    /// so a result committed after the initial list but before subscription
    /// would otherwise be skipped. Reconciliation preserves any event that
    /// races this lightweight post-ready list.
    func refreshResultArtifactsAfterEventStreamReady(
        machineID: String,
        using client: HerdrAPIClient,
        expectedGeneration: Int
    ) async throws {
        _ = try await refreshResultArtifacts(
            machineID: machineID,
            using: client,
            expectedGeneration: expectedGeneration
        )
    }

    /// Exposed at internal visibility for deterministic tests.
    func setLastRelevantEventAt(_ instant: ContinuousClock.Instant?, for machineID: String) {
        var runtime = runtimes[machineID] ?? MachineRuntime()
        runtime.lastRelevantEventAt = instant
        runtimes[machineID] = runtime
    }

    /// Exposed at internal visibility for deterministic tests.
    func noteFleetRefreshNeeded(
        machineID: String,
        client: HerdrAPIClient,
        expectedGeneration: Int
    ) {
        var runtime = runtimes[machineID] ?? MachineRuntime()
        let now = ContinuousClock().now
        if let lastRelevantEventAt = runtime.lastRelevantEventAt,
           lastRelevantEventAt.duration(to: now) > fleetRefreshQuietWindow {
            runtime.consecutiveBoringRefreshes = 0
        }
        runtime.lastRelevantEventAt = now
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
                    let window = self.currentFleetRefreshWindow(forMachine: machineID)
                    do { try await clock.sleep(until: completed.advanced(by: window)) }
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
        if state == .live {
            drainPendingRemoteReadAcknowledgements(machineID: machineID)
        }
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
        userDefaults.set(false, forKey: "herdr.demoMode")
        userDefaults.set(true, forKey: "herdr.completedSetup")
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
