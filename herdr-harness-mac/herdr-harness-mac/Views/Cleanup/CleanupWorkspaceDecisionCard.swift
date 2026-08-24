import SwiftUI

struct CleanupWorkspaceDecisionCard: View {
    let workspace: CleanupWorkspaceReport
    let panes: [CleanupPaneReport]
    let isSelected: Bool
    let isPaneSelected: (CleanupPaneReport) -> Bool
    let toggleWorkspace: () -> Void
    let togglePane: (CleanupPaneReport) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Label(workspaceTitle, systemImage: "rectangle.3.group.fill")
                        .herdrFont(.headline, weight: .bold)
                        .foregroundStyle(HerdrTheme.text)
                    Text(workspaceMetrics)
                        .herdrFont(.caption, monospaced: true)
                        .foregroundStyle(HerdrTheme.mist)
                }
                Spacer()
                workspaceSelectionControl
            }

            if let summary = workspace.summary ?? workspace.workspaceReason, !summary.isEmpty {
                Text(summary)
                    .herdrFont(.body)
                    .foregroundStyle(HerdrTheme.mist)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !workspace.workspaceBlockedBy.isEmpty {
                CleanupRailChipsView(codes: workspace.workspaceBlockedBy)
            }

            Divider()
                .overlay(HerdrTheme.surface)

            ForEach(panes) { pane in
                CleanupPaneDecisionRow(
                    pane: pane,
                    isSelected: isPaneSelected(pane),
                    isIncludedByWorkspace: isSelected,
                    toggleSelection: { togglePane(pane) }
                )
            }
        }
        .padding(14)
        .background(HerdrTheme.graphite)
        .clipShape(.rect(cornerRadius: 14))
        .accessibilityIdentifier("cleanup-workspace-\(workspace.workspaceID)")
    }

    @ViewBuilder
    private var workspaceSelectionControl: some View {
        if workspace.workspaceSafeToClose, workspace.panes.allSatisfy(\.safeToClose) {
            Button(isSelected ? "Keep workspace open" : "Close entire workspace", systemImage: isSelected ? "checkmark.square.fill" : "square", action: toggleWorkspace)
                .buttonStyle(.plain)
                .herdrFont(.caption, weight: .bold)
                .foregroundStyle(isSelected ? HerdrTheme.signal : HerdrTheme.mist)
                .accessibilityIdentifier("cleanup-workspace-checkbox-\(workspace.workspaceID)")
        } else {
            Label(
                workspace.workspaceBlockedBy.isEmpty ? "Judge recommends keeping workspace" : "Workspace protected",
                systemImage: workspace.workspaceBlockedBy.isEmpty ? "hand.raised.fill" : "lock.shield.fill"
            )
                .herdrFont(.caption, weight: .bold)
                .foregroundStyle(workspace.workspaceBlockedBy.isEmpty ? HerdrTheme.mist : HerdrTheme.working)
        }
    }

    private var workspaceTitle: String { workspace.title ?? workspace.label ?? workspace.workspaceID }

    private var workspaceMetrics: String {
        let ready = workspace.panes.count(where: \.safeToClose)
        let keep = workspace.panes.count - ready
        let protected = workspace.panes.count(where: { !$0.blockedBy.isEmpty })
        var parts = ["\(ready) ready", "\(keep) keep open"]
        if protected > 0 { parts.append("\(protected) safety protected") }
        parts.append("Git \(workspace.git.state.rawValue)")
        return parts.joined(separator: " · ")
    }
}
