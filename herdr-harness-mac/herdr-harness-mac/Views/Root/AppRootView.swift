import SwiftUI

/// Which view the detail column is showing. The Mac shell has no tab bar, so
/// this is what replaced `AppTab` for the two non-settings destinations plus
/// the workspace overview that only iPad ever showed as a middle column.
enum HerdrDetailScope: String, CaseIterable, Identifiable, Hashable, Sendable {
    case session
    case workspace
    case activeWork
    case fleet
    case attention
    case activity

    var id: String { rawValue }

    /// Destinations represented by the central segmented picker. Fleet has a
    /// dedicated toolbar control so it remains easy to find without adding a
    /// second Fleet affordance to the window chrome.
    static let pickerCases: [HerdrDetailScope] = [
        .session,
        .workspace,
        .activeWork,
        .attention,
        .activity,
    ]

    var label: String {
        switch self {
        case .session: "Session"
        case .workspace: "Workspace"
        case .activeWork: "Active Work"
        case .fleet: "Fleet"
        case .attention: "Attention"
        case .activity: "Activity"
        }
    }

    var symbol: String {
        switch self {
        case .session: "bubble.left.and.bubble.right"
        case .workspace: "rectangle.3.group"
        case .activeWork: "point.topleft.down.to.point.bottomright.curvepath"
        case .fleet: "macwindow.on.rectangle"
        case .attention: "bell.badge"
        case .activity: "clock.arrow.circlepath"
        }
    }
}

/// Window-shell state that the menu bar and the window content both drive.
/// Everything durable still lives in `HerdrAppModel`; this only holds what the
/// iOS app kept in view-local `@State` (the tab selection and a sheet flag).
@MainActor
@Observable
final class HerdrShellState {
    var detailScope: HerdrDetailScope = .session
    var isCreatingWorkspace = false
    var isAgentPresented = false
    /// Navigate ▸ Jump to Pane…. A pasted reference, not a picker: the ids
    /// come from outside the app — a URL, a log line, a message — which is
    /// exactly the case the ⌘K palette cannot serve.
    var isJumpToPanePresented = false
    var jumpToPaneInput = ""
    var agentInitialPrompt: String?
    var isCommandPalettePresented = false
    private(set) var commandPaletteFocusRequest = 0

    /// Browser-style back/forward over the places the detail column has been.
    ///
    /// Session-only by design: pane ids are machine-scoped and the fleet is
    /// re-fetched on every launch, so a restored stack would be mostly dead ids.
    private(set) var history = NavigationHistory()

    /// Present the global pane navigator. Incrementing the request also lets a
    /// repeated ⌘K put keyboard focus back in its search field.
    func presentCommandPalette() {
        isCommandPalettePresented = true
        commandPaletteFocusRequest &+= 1
    }

    func dismissCommandPalette() {
        isCommandPalettePresented = false
    }

    /// Bring the selected pane's session to the front.
    ///
    /// Routing has to be an explicit *intent*, not something inferred from
    /// `selectedPaneID` changing: clicking the pane you are already on (from
    /// the attention deck, the sidebar, or the workspace overview) assigns the
    /// same ID, so a change observer would never fire and the click would be
    /// dead.
    func showSession() {
        detailScope = .session
    }

    func showActiveWork() {
        detailScope = .activeWork
    }

    func presentAgent(prompt: String? = nil) {
        agentInitialPrompt = prompt
        isAgentPresented = true
    }

    /// Show a workspace's tab/pane overview — what iOS navigated to when you
    /// opened a workspace rather than one of its panes.
    func showWorkspace(id: String, model: HerdrAppModel) {
        guard model.workspace(id: id) != nil else { return }
        model.selectedWorkspaceID = id
        // Deliberately clears the pane: selecting one would bounce the detail
        // back to `.session` through the pane observer below.
        model.selectedPaneID = nil
        detailScope = .workspace
        recordVisit(for: model)
    }

    /// Scope-only destinations (Active Work, Fleet, Attention, and Activity).
    func show(_ scope: HerdrDetailScope, model: HerdrAppModel) {
        detailScope = scope
        recordVisit(for: model)
    }

    /// The scope actually rendered: `.session` falls back to the workspace
    /// overview when no pane is selected, and to the attention deck when
    /// nothing is selected at all.
    func resolvedScope(for model: HerdrAppModel) -> HerdrDetailScope {
        switch detailScope {
        case .session:
            if model.pane(id: model.selectedPaneID) != nil { return .session }
            if model.workspace(id: model.selectedWorkspaceID) != nil { return .workspace }
            return .attention
        case .workspace:
            return model.workspace(id: model.selectedWorkspaceID) != nil ? .workspace : .attention
        case .activeWork:
            return .activeWork
        case .fleet:
            return .fleet
        case .attention:
            return .attention
        case .activity:
            return .activity
        }
    }

    /// The destination currently on screen. Reads `resolvedScope(for:)` rather
    /// than the raw `detailScope` so a `.session` with no pane is recorded as
    /// the workspace overview or the attention deck the user is actually
    /// looking at — the same reason the toolbar picker reads resolved
    /// (`WorkspaceNavigationView.scopeSelection`).
    func currentDestination(for model: HerdrAppModel) -> HerdrDestination? {
        switch resolvedScope(for: model) {
        case .session: model.selectedPaneID.map(HerdrDestination.pane)
        case .workspace: model.selectedWorkspaceID.map(HerdrDestination.workspace)
        case .activeWork: .activeWork
        case .fleet: .fleet
        case .attention: .attention
        case .activity: .activity
        }
    }

    /// Records where the shell just landed.
    ///
    /// Recorded after the fact rather than from the requested destination:
    /// `HerdrAppModel.openPane(id:)` can defer an unknown pane
    /// (`pendingPaneRoutes`) and `openPane(rawPaneID:machineID:)` resolves the
    /// scoped id internally, so only the post-routing state is truthful. A
    /// route that did not land records nothing.
    func recordVisit(for model: HerdrAppModel) {
        guard let destination = currentDestination(for: model) else { return }
        history.record(destination)
    }

    func openPane(id paneID: String, model: HerdrAppModel) {
        showSession()
        model.openPane(id: paneID)
        recordVisit(for: model)
    }

    func openPane(rawPaneID: String, machineID: String?, model: HerdrAppModel) {
        showSession()
        model.openPane(rawPaneID: rawPaneID, machineID: machineID)
        recordVisit(for: model)
    }

    /// Routes to a pasted pane reference, recording it in the history like any
    /// other visit.
    ///
    /// Goes through `openPane(rawPaneID:machineID:)` rather than
    /// `openPane(id:)` because that path already toasts when the pane is not in
    /// the connected fleet. `openPane(id:)` would instead park the id as a
    /// pending route and wait silently, which is right for a notification tap
    /// arriving before the fleet loads and wrong for someone who just pressed
    /// a button.
    func jumpToPane(reference: String, model: HerdrAppModel) {
        guard let normalized = PaneReference.normalize(reference) else {
            model.toastMessage = "That doesn't look like a pane id"
            return
        }
        showSession()
        if let scoped = MachineScopedID.split(normalized) {
            model.openPane(rawPaneID: scoped.rawID, machineID: scoped.machineID)
        } else {
            model.openPane(rawPaneID: normalized, machineID: nil)
        }
        recordVisit(for: model)
    }

    @discardableResult
    func goBack(model: HerdrAppModel) -> Bool {
        guard let destination = history.goBack(isAlive: { isAlive($0, model: model) }) else { return false }
        apply(destination, model: model)
        return true
    }

    @discardableResult
    func goForward(model: HerdrAppModel) -> Bool {
        guard let destination = history.goForward(isAlive: { isAlive($0, model: model) }) else { return false }
        apply(destination, model: model)
        return true
    }

    /// Applies a remembered destination WITHOUT recording it — otherwise every
    /// Back would push a new entry and Forward could never be reached.
    private func apply(_ destination: HerdrDestination, model: HerdrAppModel) {
        switch destination {
        case let .pane(id):
            detailScope = .session
            model.openPane(id: id)          // clears alerts + repairs selectedWorkspaceID
        case let .workspace(id):
            model.selectedWorkspaceID = id
            model.selectedPaneID = nil      // mirrors showWorkspace(id:model:)
            detailScope = .workspace
        case .activeWork: detailScope = .activeWork
        case .fleet: detailScope = .fleet
        case .attention: detailScope = .attention
        case .activity: detailScope = .activity
        }
        history.setCurrent(destination)     // bypasses record() deliberately, see NavigationHistory
    }

    private func isAlive(_ destination: HerdrDestination, model: HerdrAppModel) -> Bool {
        switch destination {
        case let .pane(id): model.pane(id: id) != nil
        case let .workspace(id): model.workspace(id: id) != nil
        case .activeWork, .fleet, .attention, .activity: true
        }
    }

    func pruneHistory(for model: HerdrAppModel) {
        history.prune(isAlive: { isAlive($0, model: model) })
    }

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }
}

struct AppRootView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var shell: HerdrShellState
    @Bindable var activeWorkStore: ActiveWorkStore
    let driver: HerdrConnectionDriver
    let hudController: HerdrHudController
    let hudSession: HerdrHudSession
    let hudNotes: HerdrHudNotesState
    let agentSettings: AgentModelSettingsStore
    let promptSettings: HerdrPromptSettingsStore
    let fontScale: HerdrFontScaleStore
    @Environment(HerdPulseCoordinator.self) private var herdPulse
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var statusHapticTracker = AgentStatusHapticTracker()
    @State private var hapticPulse = HerdrHapticPulse()

    var body: some View {
        rootContent
            .overlay {
                commandPaletteOverlay
            }
            .animation(.snappy, value: shell.isCommandPalettePresented)
    }

    private var rootContent: some View {
        Group {
            if model.hasCompletedSetup {
                WorkspaceNavigationView(
                    model: model,
                    shell: shell,
                    activeWorkStore: activeWorkStore
                )
            } else {
                OnboardingView(model: model)
            }
        }
        // The event stream and the pulse feed belong to the process, not this
        // window — see `HerdrConnectionDriver`. The window only nudges them.
        .onChange(of: model.connectionGeneration, initial: true) { _, _ in
            driver.syncConnection(model: model)
        }
        .onChange(of: model.hasCompletedSetup) { _, _ in
            driver.syncConnection(model: model)
        }
        .onAppear {
            driver.startPulse(model: model, pulse: herdPulse)
            hudController.configure(model: model, session: hudSession, notes: hudNotes, fontScale: fontScale)
        }
        .task {
            if let paneID = HerdrMacAppDelegate.takePendingPaneID() {
                openPane(id: paneID)
            }
            for await notification in NotificationCenter.default.notifications(named: .herdrOpenPane) {
                guard let paneID = notification.object as? String else { continue }
                // Drain the static the delegate also set: handled here, it must
                // not be replayed the next time this window is re-created.
                _ = HerdrMacAppDelegate.takePendingPaneID()
                openPane(id: paneID)
            }
        }
        .task(id: model.hasCompletedSetup && model.smartAlertsEnabled && !model.isDemoMode) {
            await model.prepareSmartAlerts()
        }
        // Fleet-transition feedback. iOS hung this on the always-alive
        // Workspaces tab root; the Mac's equivalent always-alive surface is the
        // window root, so it lives here.
        .onChange(of: agentStatuses, initial: true) { _, statuses in
            if let event = statusHapticTracker.observe(statuses) {
                hapticPulse.fire(event)
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            statusHapticTracker.setSceneActive(
                phase == .active,
                isDemoMode: model.isDemoMode,
                statuses: agentStatuses
            )
        }
        .onChange(of: model.refreshTick) {
            statusHapticTracker.recordRefresh(statuses: agentStatuses)
        }
        .herdrHaptic(trigger: hapticPulse)
        .onOpenURL(perform: openURL)
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL {
                openURL(url)
            }
        }
        .onChange(of: model.selectedPaneID) { _, newValue in
            // Opening a pane — from the sidebar, a deep link, or a notification
            // tap — always brings the session back to the front.
            if newValue != nil { shell.detailScope = .session }
        }
        // Panes close and machines drop; a Back button that offers a dead id and
        // then no-ops is worse than one that is greyed out. `repairNavigation`
        // clears the live selection on the same revision — this clears the trail.
        .onChange(of: model.fleetRevision) { shell.pruneHistory(for: model) }
        .sheet(isPresented: $shell.isCreatingWorkspace) {
            CreateWorkspaceView { label, cwd in
                let machineID: String?
                if case let .machine(id) = model.machineScope {
                    machineID = id
                } else {
                    machineID = model.machines.first?.id
                }
                return await model.createWorkspace(label: label, cwd: cwd, machineID: machineID)
            }
            .frame(minWidth: 460, minHeight: 340)
        }
        .sheet(isPresented: $shell.isAgentPresented) {
            HeadlessAgentView(
                model: model,
                initialPrompt: shell.agentInitialPrompt,
                agentSettings: agentSettings,
                promptSettings: promptSettings
            ) { pane in
                openPane(id: pane.id)
            }
            .onDisappear { shell.agentInitialPrompt = nil }
        }
        .alert("Jump to pane", isPresented: $shell.isJumpToPanePresented) {
            TextField("w1:p2", text: $shell.jumpToPaneInput)
                .accessibilityIdentifier("jump-to-pane-field")
            Button("Cancel", role: .cancel) { shell.jumpToPaneInput = "" }
            Button("Jump") {
                let reference = shell.jumpToPaneInput
                shell.jumpToPaneInput = ""
                shell.jumpToPane(reference: reference, model: model)
            }
            .disabled(PaneReference.normalize(shell.jumpToPaneInput) == nil)
        } message: {
            Text("Paste a pane id, a machine-scoped id, or a herdr:// link. Percent-encoded ids work too.")
        }
        .overlay(alignment: .top) {
            if let message = model.toastMessage {
                ToastView(message: message, dismiss: model.clearToast)
                    .padding(.top, 8)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.toastMessage)
        .alert(
            "Connection issue",
            isPresented: $model.isShowingError
        ) {
            Button("Dismiss", role: .cancel, action: model.clearError)
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }

    /// Deep links and notification taps always land on the session, including
    /// when they name the pane that is already selected.
    private func openPane(id paneID: String) {
        shell.openPane(id: paneID, model: model)
    }

    private func openURL(_ url: URL) {
        guard let paneID = HerdrAppModel.paneID(from: url) else { return }
        openPane(id: paneID)
    }

    private func openCommandPaletteEntry(_ entry: CommandPaletteEntry) {
        shell.dismissCommandPalette()
        openPane(id: entry.paneID)
    }

    @ViewBuilder
    private var commandPaletteOverlay: some View {
        if shell.isCommandPalettePresented, model.hasCompletedSetup {
            CommandPaletteView(
                entries: CommandPaletteIndex.entries(
                    workspaces: model.workspaces,
                    machines: model.machines
                ),
                focusRequest: shell.commandPaletteFocusRequest,
                dismiss: shell.dismissCommandPalette,
                select: openCommandPaletteEntry
            )
            .transition(commandPaletteTransition)
        }
    }

    private var commandPaletteTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .scale(scale: 0.97, anchor: .top).combined(with: .opacity)
    }

    private var agentStatuses: [String: AgentStatus] {
        AgentStatusHapticTracker.snapshot(model.workspaces)
    }
}
