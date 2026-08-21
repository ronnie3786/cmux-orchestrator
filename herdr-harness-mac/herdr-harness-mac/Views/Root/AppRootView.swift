import SwiftUI

/// Which view the detail column is showing. The Mac shell has no tab bar, so
/// this is what replaced `AppTab` for the two non-settings destinations plus
/// the workspace overview that only iPad ever showed as a middle column.
enum HerdrDetailScope: String, CaseIterable, Identifiable, Hashable, Sendable {
    case session
    case workspace
    case attention

    var id: String { rawValue }

    var label: String {
        switch self {
        case .session: "Session"
        case .workspace: "Workspace"
        case .attention: "Attention"
        }
    }

    var symbol: String {
        switch self {
        case .session: "bubble.left.and.bubble.right"
        case .workspace: "rectangle.3.group"
        case .attention: "bell.badge"
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

    /// Show a workspace's tab/pane overview — what iOS navigated to when you
    /// opened a workspace rather than one of its panes.
    func showWorkspace(id: String, model: HerdrAppModel) {
        guard model.workspace(id: id) != nil else { return }
        model.selectedWorkspaceID = id
        // Deliberately clears the pane: selecting one would bounce the detail
        // back to `.session` through the pane observer below.
        model.selectedPaneID = nil
        detailScope = .workspace
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
        case .attention:
            return .attention
        }
    }
}

struct AppRootView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var shell: HerdrShellState
    let driver: HerdrConnectionDriver
    @Environment(HerdPulseCoordinator.self) private var herdPulse
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var statusHapticTracker = AgentStatusHapticTracker()
    @State private var hapticPulse = HerdrHapticPulse()

    var body: some View {
        Group {
            if model.hasCompletedSetup {
                WorkspaceNavigationView(model: model, shell: shell)
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
        .onChange(of: model.lastUpdated) {
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
        shell.showSession()
        model.openPane(id: paneID)
    }

    private func openURL(_ url: URL) {
        guard let paneID = HerdrAppModel.paneID(from: url) else { return }
        openPane(id: paneID)
    }

    private var agentStatuses: [String: AgentStatus] {
        AgentStatusHapticTracker.snapshot(model.workspaces)
    }
}
