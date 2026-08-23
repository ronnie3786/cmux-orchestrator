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

    struct StarredGroup: Identifiable, Equatable {
        let workspace: HerdrWorkspace
        let chats: [HerdrPane]

        var id: String { "starred:\(workspace.id)" }
    }

    struct MachineGroup: Identifiable, Equatable {
        let machine: HerdrMachine
        let state: ConnectionState
        let isExpanded: Bool
        let entries: [ProjectEntry]

        var id: String { "machine:\(machine.id)" }
    }

    static func build(
        workspaces: [HerdrWorkspace],
        query: String,
        collapsedWorkspaceIDs: Set<String>,
        starredIDs: Set<String> = []
    ) -> [ProjectEntry] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return workspaces.sorted { $0.number < $1.number }.compactMap { workspace in
            buildEntry(
                for: workspace,
                query: trimmedQuery,
                collapsedWorkspaceIDs: collapsedWorkspaceIDs,
                starredIDs: starredIDs
            )
        }
    }

    static func starredGroups(
        workspaces: [HerdrWorkspace],
        query: String,
        starredIDs: Set<String>,
        machines: [HerdrMachine] = []
    ) -> [StarredGroup] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let machineOrder = Dictionary(uniqueKeysWithValues: machines.enumerated().map { ($0.element.id, $0.offset) })
        return workspaces
            .sorted {
                let lhsMachine = MachineScopedID.split($0.id)?.machineID
                let rhsMachine = MachineScopedID.split($1.id)?.machineID
                let lhsOrder = lhsMachine.flatMap { machineOrder[$0] } ?? Int.max
                let rhsOrder = rhsMachine.flatMap { machineOrder[$0] } ?? Int.max
                if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                return $0.number < $1.number
            }
            .compactMap { workspace in
                let chats = workspace.panes
                    .filter { starredIDs.contains($0.id) && matchesPaneQuery($0, query: trimmedQuery) }
                    .sorted { $0.paneID < $1.paneID }
                guard !chats.isEmpty else { return nil }
                return StarredGroup(workspace: workspace, chats: chats)
            }
    }

    static func machineGroups(
        machines: [HerdrMachine],
        states: [String: ConnectionState],
        workspaces: [HerdrWorkspace],
        query: String,
        collapsedMachineIDs: Set<String>,
        collapsedWorkspaceIDs: Set<String>,
        starredIDs: Set<String> = []
    ) -> [MachineGroup] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return machines.map { machine in
            MachineGroup(
                machine: machine,
                state: states[machine.id] ?? .disconnected,
                isExpanded: trimmedQuery.isEmpty ? !collapsedMachineIDs.contains(machine.id) : true,
                entries: build(
                    workspaces: workspaces.filter { $0.machineID == machine.id },
                    query: query,
                    collapsedWorkspaceIDs: collapsedWorkspaceIDs,
                    starredIDs: starredIDs
                )
            )
        }
    }

    static func machineGroups(
        machines: [HerdrMachine],
        states: [String: ConnectionState],
        entries: [ProjectEntry],
        query: String,
        collapsedMachineIDs: Set<String>
    ) -> [MachineGroup] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return machines.map { machine in
            MachineGroup(
                machine: machine,
                state: states[machine.id] ?? .disconnected,
                isExpanded: trimmedQuery.isEmpty ? !collapsedMachineIDs.contains(machine.id) : true,
                entries: entries.filter { $0.workspace.machineID == machine.id }
            )
        }
    }

    private static func buildEntry(
        for workspace: HerdrWorkspace,
        query: String,
        collapsedWorkspaceIDs: Set<String>,
        starredIDs: Set<String>
    ) -> ProjectEntry? {
        let sortedTabs = workspace.tabs.sorted { $0.number < $1.number }
        let tabIDs = Set(sortedTabs.map(\.id))
        let workspaceMatches: Bool
        let matchingTabIDs: Set<String>
        let matchingPaneIDs: Set<String>
        if query.isEmpty {
            workspaceMatches = false
            matchingTabIDs = []
            matchingPaneIDs = []
        } else {
            workspaceMatches = workspace.label.localizedStandardContains(query)
                || workspace.displayPath.localizedStandardContains(query)
            matchingTabIDs = Set(sortedTabs.filter {
                $0.label.localizedStandardContains(query)
            }.map(\.id))
            matchingPaneIDs = Set(workspace.panes.filter {
                matchesPaneQuery($0, query: query)
            }.map(\.id))
        }

        guard query.isEmpty || workspaceMatches || !matchingTabIDs.isEmpty || !matchingPaneIDs.isEmpty else {
            return nil
        }

        let filteredPanes: [HerdrPane]
        if query.isEmpty || workspaceMatches {
            filteredPanes = workspace.panes.filter { !starredIDs.contains($0.id) }
        } else {
            filteredPanes = workspace.panes.filter {
                !starredIDs.contains($0.id)
                    && (matchingPaneIDs.contains($0.id) || matchingTabIDs.contains($0.tabID))
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

    private static func matchesPaneQuery(_ pane: HerdrPane, query: String) -> Bool {
        query.isEmpty || pane.displayTitle.localizedStandardContains(query)
    }
}
