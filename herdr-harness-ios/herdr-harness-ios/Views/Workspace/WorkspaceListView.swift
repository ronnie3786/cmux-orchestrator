import SwiftUI

struct WorkspaceListView: View {
    @Bindable var model: HerdrAppModel
    let selectWorkspace: (HerdrWorkspace) -> Void
    let selectPane: (HerdrPane) -> Void
    @State private var presentedSheet: WorkspaceListSheet?

    var body: some View {
        ZStack {
            HerdrBackground()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    WorkspaceHeader(model: model) {
                        presentedSheet = .create
                    }
                    FleetSummaryView(model: model)

                    if !model.attentionPanes.isEmpty {
                        AttentionStrip(model: model, selectPane: selectPane)
                    }

                    WorkspaceFilterBar(model: model)

                    if model.visibleWorkspaces.isEmpty {
                        emptyState
                            .frame(maxWidth: .infinity)
                            .padding(.top, 42)
                    } else {
                        ForEach(model.visibleWorkspaces) { workspace in
                            Button {
                                selectWorkspace(workspace)
                            } label: {
                                WorkspaceCardView(workspace: workspace)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("workspace-\(workspace.id)")
                            .accessibilityHint("Shows \(workspace.paneCount) panes")
                        }
                    }
                }
                .padding(.horizontal, HerdrTheme.pagePadding)
                .padding(.top, 18)
                .padding(.bottom, 34)
            }
            .scrollIndicators(.hidden)
            .refreshable { await model.refresh() }
        }
        .navigationTitle("Workspaces")
        .toolbar(.hidden, for: .navigationBar)
        .searchable(text: $model.searchText, prompt: "Workspace, pane, or path")
        .sheet(item: $presentedSheet) { _ in
            CreateWorkspaceView { label, cwd in
                let created = await model.createWorkspace(label: label, cwd: cwd)
                if created { presentedSheet = nil }
                return created
            }
            .presentationDetents([.medium])
        }
    }

    private var emptyState: some View {
        Group {
            if model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               model.filter == .all {
                ContentUnavailableView(
                    "No Herdr workspaces",
                    systemImage: "rectangle.3.group",
                    description: Text("Create a workspace here or on your Mac to begin.")
                )
            } else {
                ContentUnavailableView.search
            }
        }
    }
}

private enum WorkspaceListSheet: String, Identifiable {
    case create
    var id: String { rawValue }
}
