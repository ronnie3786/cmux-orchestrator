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
        let isExpanded: Bool
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
        collapsedTabIDs: Set<String> = [],
        starredIDs: Set<String> = [],
        recentOnly: Bool = false,
        now: Date = Date()
    ) -> [ProjectEntry] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return workspaces.sorted { $0.number < $1.number }.compactMap { workspace in
            buildEntry(
                for: workspace,
                query: trimmedQuery,
                collapsedWorkspaceIDs: collapsedWorkspaceIDs,
                collapsedTabIDs: collapsedTabIDs,
                starredIDs: starredIDs,
                recentOnly: recentOnly,
                now: now
            )
        }
    }

    static func starredGroups(
        workspaces: [HerdrWorkspace],
        query: String,
        starredIDs: Set<String>,
        machines: [HerdrMachine] = [],
        recentOnly: Bool = false,
        now: Date = Date()
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
                    .filter {
                        starredIDs.contains($0.id)
                            && matchesPaneQuery($0, query: trimmedQuery)
                            && matchesRecent($0, recentOnly: recentOnly, now: now)
                    }
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
        collapsedTabIDs: Set<String> = [],
        starredIDs: Set<String> = [],
        recentOnly: Bool = false,
        now: Date = Date()
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
                    collapsedTabIDs: collapsedTabIDs,
                    starredIDs: starredIDs,
                    recentOnly: recentOnly,
                    now: now
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
        collapsedTabIDs: Set<String> = [],
        starredIDs: Set<String>,
        recentOnly: Bool = false,
        now: Date = Date()
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
                    && matchesRecent($0, recentOnly: recentOnly, now: now)
            }.map(\.id))
        }

        guard query.isEmpty || workspaceMatches || !matchingTabIDs.isEmpty || !matchingPaneIDs.isEmpty else {
            return nil
        }

        let filteredPanes: [HerdrPane]
        if query.isEmpty || workspaceMatches {
            filteredPanes = workspace.panes.filter {
                !starredIDs.contains($0.id)
                    && matchesRecent($0, recentOnly: recentOnly, now: now)
            }
        } else {
            filteredPanes = workspace.panes.filter {
                !starredIDs.contains($0.id)
                    && (matchingPaneIDs.contains($0.id) || matchingTabIDs.contains($0.scopedTabID))
                    && matchesRecent($0, recentOnly: recentOnly, now: now)
            }
        }

        let sections = sortedTabs.compactMap { tab -> SectionEntry? in
            let chats = filteredPanes
                .filter { $0.scopedTabID == tab.id }
                .sorted { $0.paneID < $1.paneID }
            guard (query.isEmpty && !recentOnly) || !chats.isEmpty || (!recentOnly && matchingTabIDs.contains(tab.id)) else { return nil }
            return SectionEntry(
                tab: tab,
                isExpanded: query.isEmpty ? !collapsedTabIDs.contains(tab.id) : true,
                chats: chats
            )
        }
        let looseChats = filteredPanes
            .filter { !tabIDs.contains($0.scopedTabID) }
            .sorted { $0.paneID < $1.paneID }

        guard !recentOnly || !sections.isEmpty || !looseChats.isEmpty else { return nil }

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

    private static func matchesRecent(_ pane: HerdrPane, recentOnly: Bool, now: Date) -> Bool {
        !recentOnly || (pane.firstSeenAt.map { Calendar.autoupdatingCurrent.isDate($0, inSameDayAs: now) } ?? false)
    }
}
