import SwiftUI

struct AttentionNavigationView: View {
    @Bindable var model: HerdrAppModel
    /// Type-erased because this stack carries two route types: panes
    /// (`WorkspaceRoute`) and the Activity feed (`AttentionRoute`). A
    /// homogeneous `[WorkspaceRoute]` binding cannot represent the second, and
    /// a value-based link to it would silently do nothing.
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            AttentionView(
                model: model,
                selectPane: { pane, _ in openPane(pane) },
                openActivity: { path.append(AttentionRoute.activity) }
            )
            // Both destinations sit on the stack's root content, so a pane
            // pushed from two levels deep (Attention → Activity → pane) still
            // resolves.
            .navigationDestination(for: WorkspaceRoute.self) { route in
                if case let .pane(id) = route, let pane = model.pane(id: id) {
                    PaneSessionView(model: model, pane: pane, hidesAppTabBar: true)
                        .id(pane.id)
                }
            }
            .navigationDestination(for: AttentionRoute.self) { route in
                switch route {
                case .activity:
                    ActivityFeedView(model: model, selectPane: openPane)
                }
            }
        }
    }

    private func openPane(_ pane: HerdrPane) {
        model.selectedWorkspaceID = model.workspace(containing: pane)?.id
        model.selectedPaneID = pane.id
        model.clearAlertsForPaneOnOpen(pane)
        path.append(WorkspaceRoute.pane(pane.id))
    }
}
