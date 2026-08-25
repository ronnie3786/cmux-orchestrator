import Foundation

struct CleanupSelectionPlan: Equatable {
    private(set) var paneIDs: Set<String> = []
    private(set) var workspaceIDs: Set<String> = []

    mutating func seed(
        with workspaces: [CleanupWorkspaceReport],
        preferredPaneIDs: Set<String>? = nil
    ) {
        guard paneIDs.isEmpty, workspaceIDs.isEmpty else { return }
        if let preferredPaneIDs {
            paneIDs = Set(workspaces.flatMap(\.panes).filter {
                $0.safeToClose && preferredPaneIDs.contains($0.paneID)
            }.map(\.paneID))
            return
        }
        paneIDs = Set(workspaces.flatMap { workspace in
            var panes = workspace.panes.filter(\.safeToClose)
            // Selecting every pane would implicitly collapse the workspace.
            // When Git is protected, keep one useful anchor pane unchecked by
            // default so the preview matches what apply can safely complete.
            if workspace.git.state != .clean,
               panes.count == workspace.panes.count,
               let anchor = panes.first(where: { $0.piSession?.active == true }) ?? panes.last {
                panes.removeAll(where: { $0.paneID == anchor.paneID })
            }
            return panes.map(\.paneID)
        })
    }

    mutating func togglePane(_ pane: CleanupPaneReport, in workspace: CleanupWorkspaceReport) {
        guard pane.safeToClose else { return }
        if workspaceIDs.remove(workspace.workspaceID) != nil {
            paneIDs.formUnion(
                workspace.panes
                    .filter { $0.safeToClose && $0.paneID != pane.paneID }
                    .map(\.paneID)
            )
            return
        }
        if paneIDs.contains(pane.paneID) {
            paneIDs.remove(pane.paneID)
        } else {
            paneIDs.insert(pane.paneID)
        }
    }

    mutating func toggleWorkspace(_ workspace: CleanupWorkspaceReport) {
        guard workspace.workspaceSafeToClose, workspace.panes.allSatisfy(\.safeToClose) else { return }
        if workspaceIDs.contains(workspace.workspaceID) {
            workspaceIDs.remove(workspace.workspaceID)
        } else {
            workspaceIDs.insert(workspace.workspaceID)
            paneIDs.subtract(workspace.panes.map(\.paneID))
        }
    }

    mutating func clear() {
        paneIDs.removeAll()
        workspaceIDs.removeAll()
    }

    func contains(_ pane: CleanupPaneReport) -> Bool {
        paneIDs.contains(pane.paneID)
    }

    func contains(_ workspace: CleanupWorkspaceReport) -> Bool {
        workspaceIDs.contains(workspace.workspaceID)
    }

    func normalizedPaneIDs(in workspaces: [CleanupWorkspaceReport]) -> [String] {
        let superseded = Set(workspaces
            .filter { workspaceIDs.contains($0.workspaceID) }
            .flatMap(\.panes)
            .map(\.paneID))
        return paneIDs.subtracting(superseded).sorted()
    }

    func normalizedWorkspaceIDs() -> [String] {
        workspaceIDs.sorted()
    }

    func affectedPanes(in workspaces: [CleanupWorkspaceReport]) -> [CleanupPaneReport] {
        var seen: Set<String> = []
        var result: [CleanupPaneReport] = []
        for workspace in workspaces {
            for pane in workspace.panes where workspaceIDs.contains(workspace.workspaceID) || paneIDs.contains(pane.paneID) {
                if seen.insert(pane.paneID).inserted {
                    result.append(pane)
                }
            }
        }
        return result
    }

    func affectedWorkspaces(in workspaces: [CleanupWorkspaceReport]) -> [CleanupWorkspaceReport] {
        workspaces.filter { workspace in
            workspaceIDs.contains(workspace.workspaceID) || workspace.panes.contains(where: { paneIDs.contains($0.paneID) })
        }
    }

    func activePiSessionCount(in workspaces: [CleanupWorkspaceReport]) -> Int {
        affectedPanes(in: workspaces).count(where: { $0.piSession?.active == true })
    }

    var isEmpty: Bool { paneIDs.isEmpty && workspaceIDs.isEmpty }
}
