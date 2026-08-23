import SwiftUI

struct WorkspacePaneListView: View {
    @Bindable var model: HerdrAppModel
    let workspace: HerdrWorkspace
    let selectPane: (HerdrPane) -> Void
    @State private var isRenamingWorkspace = false
    @State private var isConfirmingWorkspaceClose = false
    @State private var workspaceName = ""
    @State private var cleanupPresenter = CleanupSheetPresenter()

    var body: some View {
        @Bindable var cleanupPresenter = cleanupPresenter
        ZStack {
            HerdrBackground()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    // Orphaned on iOS (the list screen's AttentionStrip took its
                    // slot). On the Mac this is the fleet readout above the
                    // space you are actually looking at.
                    FleetSummaryView(model: model)

                    WorkspaceHeroView(workspace: workspace)

                    ForEach(workspace.tabs) { tab in
                        tabSection(tab)
                    }

                    if workspace.tabs.isEmpty {
                        paneRows(workspace.sortedPanes)
                    }
                }
                .frame(maxWidth: Self.contentWidth, alignment: .leading)
                .padding(.horizontal, HerdrTheme.pagePadding)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .refreshable { await model.refresh() }
        }
        .navigationTitle(workspace.label)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Workspace actions", systemImage: "ellipsis.circle") {
                    Button("Focus on Mac", systemImage: "scope") {
                        Task { await model.focus(workspace) }
                    }
                    Button("Rename workspace", systemImage: "pencil") {
                        workspaceName = workspace.label
                        isRenamingWorkspace = true
                    }
                    Button("New tab", systemImage: "plus.square.on.square") {
                        Task { await model.createTab(in: workspace) }
                    }
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await model.refresh() }
                    }
                    Button("Smart Cleanup This Workspace…", systemImage: "sparkles") {
                        cleanupPresenter.present(CleanupSheetTarget(
                            id: "\(workspace.machineID)|cleanup|\(workspace.workspaceID)",
                            machineID: workspace.machineID,
                            machineName: model.machines.first(where: { $0.id == workspace.machineID })?.name ?? "this machine",
                            workspaceID: workspace.workspaceID,
                            workspaceLabel: workspace.label
                        ), using: model)
                    }
                    .disabled(!model.canControl(machineID: workspace.machineID))
                    .accessibilityIdentifier("workspace-cleanup-\(workspace.workspaceID)")
                    Divider()
                    Button("Close workspace", systemImage: "xmark.rectangle", role: .destructive) {
                        isConfirmingWorkspaceClose = true
                    }
                }
                .disabled(!model.canControl)
            }
        }
        .alert("Rename workspace", isPresented: $isRenamingWorkspace) {
            TextField("Workspace name", text: $workspaceName)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                Task { await model.rename(workspace, label: workspaceName) }
            }
            .disabled(workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("The new label appears in Herdr on every connected client.")
        }
        .confirmationDialog(
            "Close this workspace?",
            isPresented: $isConfirmingWorkspaceClose,
            titleVisibility: .visible
        ) {
            Button("Close workspace", role: .destructive) {
                Task { await model.close(workspace) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("All \(workspace.paneCount) pane processes in this workspace will stop.")
        }
        .sheet(item: $cleanupPresenter.target) { target in
            if let controller = cleanupPresenter.controller {
                CleanupSheet(target: target, controller: controller)
            }
        }
    }

    /// The overview owns the detail column of a wide window; the cards read
    /// better in a capped column than stretched across 1000pt.
    private static let contentWidth = 760.0

    private func tabSection(_ tab: HerdrTab) -> some View {
        let panes = workspace.sortedPanes.filter { $0.tabID == tab.id }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(tab.label, systemImage: "square.on.square")
                    .herdrFont(.headline, weight: .bold)
                Spacer()
                Text("^[\(panes.count) pane](inflect: true)")
                    .herdrFont(.caption)
                    .foregroundStyle(.secondary)
            }
            paneRows(panes)
        }
    }

    private func paneRows(_ panes: [HerdrPane]) -> some View {
        VStack(spacing: 10) {
            ForEach(panes) { pane in
                Button {
                    selectPane(pane)
                } label: {
                    PaneCardView(
                        pane: pane,
                        isSelected: pane.id == model.selectedPaneID
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("pane-\(pane.id)")
            }
        }
    }

}
