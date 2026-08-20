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
    @Environment(HerdPulseCoordinator.self) private var herdPulse
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if model.hasCompletedSetup {
                WorkspaceNavigationView(model: model, shell: shell)
            } else {
                OnboardingView(model: model)
            }
        }
        .task(id: model.connectionGeneration) {
            guard model.hasCompletedSetup else { return }
            await model.runConnection()
        }
        .task {
            if let paneID = HerdrMacAppDelegate.takePendingPaneID() {
                model.openPane(id: paneID)
            }
            for await notification in NotificationCenter.default.notifications(named: .herdrOpenPane) {
                guard let paneID = notification.object as? String else { continue }
                model.openPane(id: paneID)
            }
        }
        .task(id: model.hasCompletedSetup && model.smartAlertsEnabled && !model.isDemoMode) {
            await model.prepareSmartAlerts()
        }
        .task(id: herdPulseContext) {
            await herdPulse.synchronize(context: herdPulseContext)
        }
        .onOpenURL(perform: model.open)
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL {
                model.open(url: url)
            }
        }
        .onChange(of: model.selectedPaneID) { _, newValue in
            // Opening a pane — from the sidebar, a deep link, or a notification
            // tap — always brings the session back to the front.
            if newValue != nil { shell.detailScope = .session }
        }
        .sheet(isPresented: $shell.isCreatingWorkspace) {
            CreateWorkspaceView { label, cwd in
                await model.createWorkspace(label: label, cwd: cwd)
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

    private var herdPulseContext: HerdPulseSyncContext {
        return HerdPulseSyncContext(
            aggregate: HerdPulseAggregate(
                workspaces: model.workspaces,
                connectionState: model.connectionState
            ),
            serverConnection: model.activeServerConnection
        )
    }
}
