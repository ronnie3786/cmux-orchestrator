import SwiftUI

struct AppRootView: View {
    @Bindable var model: HerdrAppModel
    @Environment(HerdPulseCoordinator.self) private var herdPulse
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if model.hasCompletedSetup {
                appTabs
            } else {
                OnboardingView(model: model)
            }
        }
        .task(id: model.connectionGeneration) {
            guard model.hasCompletedSetup else { return }
            await model.runConnection()
        }
        .task {
            if let paneID = HerdrAppDelegate.takePendingPaneID() {
                model.openPane(id: paneID)
            }
            for await notification in NotificationCenter.default.notifications(named: .herdrOpenPane) {
                guard let paneID = notification.object as? String else { continue }
                model.openPane(id: paneID)
            }
        }
        .task {
            for await notification in NotificationCenter.default.notifications(named: .herdrPushToken) {
                guard let token = notification.object as? String else { continue }
                await model.registerPushDevice(token: token)
            }
        }
        .task(id: model.hasCompletedSetup && model.smartAlertsEnabled && !model.isDemoMode) {
            await model.prepareSmartAlerts()
        }
        .task(id: herdPulseContext) {
            await herdPulse.synchronize(context: herdPulseContext)
        }
        .onOpenURL(perform: model.open)
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

    private var appTabs: some View {
        TabView(selection: $model.selectedTab) {
            Tab("Workspaces", systemImage: "rectangle.3.group", value: .workspaces) {
                WorkspaceNavigationView(model: model)
            }

            Tab("Attention", systemImage: "bell.badge", value: .attention) {
                AttentionNavigationView(model: model)
            }
            .badge(model.unreadAlertCount)

            Tab("Settings", systemImage: "gearshape", value: .settings) {
                SettingsView(model: model)
            }
        }
    }
}
