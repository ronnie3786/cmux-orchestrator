import SwiftUI

struct WorkspaceNavigationView: View {
    @Bindable var model: HerdrAppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if horizontalSizeClass == .regular {
            regularNavigation
        } else {
            compactNavigation
        }
    }

    private var compactNavigation: some View {
        NavigationStack(path: $model.workspacePath) {
            WorkspaceListView(
                model: model,
                selectWorkspace: { workspace in
                    model.selectedWorkspaceID = workspace.id
                    model.workspacePath.append(.workspace(workspace.id))
                },
                selectPane: { pane in
                    model.selectedWorkspaceID = pane.workspaceID
                    model.selectedPaneID = pane.id
                    model.workspacePath = [.workspace(pane.workspaceID), .pane(pane.id)]
                }
            )
            .navigationDestination(for: WorkspaceRoute.self) { route in
                switch route {
                case let .workspace(id):
                    if let workspace = model.workspace(id: id) {
                        WorkspacePaneListView(model: model, workspace: workspace) { pane in
                            model.selectedPaneID = pane.id
                            model.workspacePath.append(.pane(pane.id))
                        }
                    }
                case let .pane(id):
                    if let pane = model.pane(id: id) {
                        PaneSessionView(model: model, pane: pane)
                    }
                }
            }
        }
    }

    private var regularNavigation: some View {
        NavigationSplitView {
            WorkspaceListView(
                model: model,
                selectWorkspace: { workspace in
                    model.selectedWorkspaceID = workspace.id
                    model.selectedPaneID = workspace.sortedPanes.first?.id
                },
                selectPane: { pane in
                    model.selectedWorkspaceID = pane.workspaceID
                    model.selectedPaneID = pane.id
                }
            )
            .navigationSplitViewColumnWidth(min: 330, ideal: 390, max: 460)
        } content: {
            if let workspace = model.workspace(id: model.selectedWorkspaceID) {
                WorkspacePaneListView(model: model, workspace: workspace) { pane in
                    model.selectedPaneID = pane.id
                }
                .navigationSplitViewColumnWidth(min: 320, ideal: 390, max: 480)
            } else {
                ContentUnavailableView(
                    "Choose a workspace",
                    systemImage: "rectangle.3.group",
                    description: Text("Its tabs and panes will appear here.")
                )
            }
        } detail: {
            if let pane = model.pane(id: model.selectedPaneID) {
                PaneSessionView(model: model, pane: pane)
            } else {
                ContentUnavailableView(
                    "Choose a pane",
                    systemImage: "terminal",
                    description: Text("Open a terminal or agent session.")
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}
