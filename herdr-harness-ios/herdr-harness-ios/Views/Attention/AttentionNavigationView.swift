import SwiftUI

struct AttentionNavigationView: View {
    @Bindable var model: HerdrAppModel
    @State private var path: [WorkspaceRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            AttentionView(model: model) { pane, alert in
                model.selectedWorkspaceID = pane.workspaceID
                model.selectedPaneID = pane.id
                path.append(.pane(pane.id))
                if let alert {
                    Task { await model.markAlertRead(alert) }
                }
            }
            .navigationDestination(for: WorkspaceRoute.self) { route in
                if case let .pane(id) = route, let pane = model.pane(id: id) {
                    PaneSessionView(model: model, pane: pane)
                }
            }
        }
    }
}
