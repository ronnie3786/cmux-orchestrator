import SwiftUI

struct AttentionNavigationView: View {
    @Bindable var model: HerdrAppModel
    @State private var path: [WorkspaceRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            AttentionView(model: model) { pane, _ in
                model.selectedWorkspaceID = model.workspace(containing: pane)?.id
                model.selectedPaneID = pane.id
                model.clearAlertsForPaneOnOpen(pane)
                path.append(.pane(pane.id))
            }
            .navigationDestination(for: WorkspaceRoute.self) { route in
                if case let .pane(id) = route, let pane = model.pane(id: id) {
                    PaneSessionView(model: model, pane: pane, hidesAppTabBar: true)
                        .id(pane.id)
                }
            }
        }
    }
}
