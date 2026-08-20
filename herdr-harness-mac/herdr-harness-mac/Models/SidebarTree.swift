import Foundation

enum SidebarTree {
    struct ProjectEntry: Identifiable, Equatable {
        let workspace: HerdrWorkspace
        let isExpanded: Bool
        let sections: [SectionEntry]
        let looseChats: [HerdrPane]

        var id: String { workspace.id }
    }

    struct SectionEntry: Identifiable, Equatable {
        let tab: HerdrTab
        let chats: [HerdrPane]

        var id: String { tab.id }
    }

    static func build(
        workspaces: [HerdrWorkspace],
        query: String,
        collapsedWorkspaceIDs: Set<String>
    ) -> [ProjectEntry] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return workspaces.sorted { $0.number < $1.number }.compactMap { workspace in
            buildEntry(
                for: workspace,
                query: trimmedQuery,
                collapsedWorkspaceIDs: collapsedWorkspaceIDs
            )
        }
    }

    private static func buildEntry(
        for workspace: HerdrWorkspace,
        query: String,
        collapsedWorkspaceIDs: Set<String>
    ) -> ProjectEntry? {
        let sortedTabs = workspace.tabs.sorted { $0.number < $1.number }
        let tabIDs = Set(sortedTabs.map(\.id))
        let workspaceMatches = workspace.label.localizedStandardContains(query)
            || workspace.displayPath.localizedStandardContains(query)
        let matchingTabIDs = Set(sortedTabs.filter {
            $0.label.localizedStandardContains(query)
        }.map(\.id))
        let matchingPaneIDs = Set(workspace.panes.filter {
            $0.displayTitle.localizedStandardContains(query)
        }.map(\.id))

        guard query.isEmpty || workspaceMatches || !matchingTabIDs.isEmpty || !matchingPaneIDs.isEmpty else {
            return nil
        }

        let filteredPanes: [HerdrPane]
        if query.isEmpty || workspaceMatches {
            filteredPanes = workspace.panes
        } else {
            filteredPanes = workspace.panes.filter {
                matchingPaneIDs.contains($0.id) || matchingTabIDs.contains($0.tabID)
            }
        }

        let sections = sortedTabs.compactMap { tab -> SectionEntry? in
            let chats = filteredPanes
                .filter { $0.tabID == tab.id }
                .sorted { $0.paneID < $1.paneID }
            guard query.isEmpty || !chats.isEmpty || matchingTabIDs.contains(tab.id) else { return nil }
            return SectionEntry(tab: tab, chats: chats)
        }
        let looseChats = filteredPanes
            .filter { !tabIDs.contains($0.tabID) }
            .sorted { $0.paneID < $1.paneID }

        return ProjectEntry(
            workspace: workspace,
            isExpanded: query.isEmpty ? !collapsedWorkspaceIDs.contains(workspace.id) : true,
            sections: sections,
            looseChats: looseChats
        )
    }
}
