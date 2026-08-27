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

    struct UnreadGroup: Identifiable, Equatable {
        let workspace: HerdrWorkspace
        let chats: [HerdrPane]

        var id: String { "unread:\(workspace.id)" }
    }

    struct MachineGroup: Identifiable, Equatable {
        let machine: HerdrMachine
        let state: ConnectionState
        let isExpanded: Bool
        let entries: [ProjectEntry]

        var id: String { "machine:\(machine.id)" }
    }

    struct StaleGroup: Identifiable, Equatable {
        let machine: HerdrMachine
        let chats: [HerdrPane]

        var id: String { "stale:\(machine.id)" }
        var workspaceIDs: [String] { Array(Set(chats.map(\.workspaceID))).sorted() }
    }

    static func build(
        workspaces: [HerdrWorkspace],
        query: String,
        collapsedWorkspaceIDs: Set<String>,
        collapsedTabIDs: Set<String> = [],
        starredIDs: Set<String> = [],
        recency: SidebarRecency = .all,
        excludedPaneIDs: Set<String> = [],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> [ProjectEntry] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return workspaces.sorted { $0.number < $1.number }.compactMap { workspace in
            buildEntry(
                for: workspace,
                query: trimmedQuery,
                collapsedWorkspaceIDs: collapsedWorkspaceIDs,
                collapsedTabIDs: collapsedTabIDs,
                starredIDs: starredIDs,
                recency: recency,
                excludedPaneIDs: excludedPaneIDs,
                now: now,
                calendar: calendar
            )
        }
    }

    static func starredGroups(
        workspaces: [HerdrWorkspace],
        query: String,
        starredIDs: Set<String>,
        machines: [HerdrMachine] = [],
        recency: SidebarRecency = .all,
        excludedPaneIDs: Set<String> = [],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
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
                            && !excludedPaneIDs.contains($0.id)
                            && matchesPaneQuery($0, query: trimmedQuery)
                            && recency.includes($0, now: now, calendar: calendar)
                    }
                    .sorted { $0.paneID < $1.paneID }
                guard !chats.isEmpty else { return nil }
                return StarredGroup(workspace: workspace, chats: chats)
            }
    }

    static func unreadGroups(
        workspaces: [HerdrWorkspace],
        query: String,
        unreadIDs: Set<String>,
        machines: [HerdrMachine] = [],
        recency: SidebarRecency = .all,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> [UnreadGroup] {
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
                let workspaceMatches = trimmedQuery.isEmpty
                    || workspace.label.localizedStandardContains(trimmedQuery)
                    || workspace.displayPath.localizedStandardContains(trimmedQuery)
                let matchingTabIDs = Set(workspace.tabs.filter {
                    $0.label.localizedStandardContains(trimmedQuery)
                }.map(\.id))
                let chats = workspace.panes
                    .filter {
                        unreadIDs.contains($0.id)
                            && (workspaceMatches
                                || matchingTabIDs.contains($0.scopedTabID)
                                || matchesPaneQuery($0, query: trimmedQuery))
                            && recency.includes($0, now: now, calendar: calendar)
                    }
                    .sorted { $0.paneID < $1.paneID }
                guard !chats.isEmpty else { return nil }
                return UnreadGroup(workspace: workspace, chats: chats)
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
        recency: SidebarRecency = .all,
        excludedPaneIDs: Set<String> = [],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
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
                    recency: recency,
                    excludedPaneIDs: excludedPaneIDs,
                    now: now,
                    calendar: calendar
                )
            )
        }
    }

    static func staleGroups(
        machines: [HerdrMachine],
        workspaces: [HerdrWorkspace],
        query: String,
        excludedPaneIDs: Set<String> = [],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> [StaleGroup] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return machines.compactMap { machine in
            let chats = workspaces
                .filter { $0.machineID == machine.id }
                .flatMap { workspace -> [HerdrPane] in
                    let workspaceMatches = trimmedQuery.isEmpty
                        || workspace.label.localizedStandardContains(trimmedQuery)
                        || workspace.displayPath.localizedStandardContains(trimmedQuery)
                    let matchingTabIDs = Set(workspace.tabs.filter {
                        $0.label.localizedStandardContains(trimmedQuery)
                    }.map(\.id))
                    return workspace.panes.filter { pane in
                        !excludedPaneIDs.contains(pane.id)
                            && PaneFreshness.isStale(pane, now: now, calendar: calendar)
                            && (workspaceMatches
                                || matchingTabIDs.contains(pane.scopedTabID)
                                || matchesPaneQuery(pane, query: trimmedQuery))
                    }
                }
                .sorted {
                    if $0.lastActivityAt != $1.lastActivityAt {
                        return ($0.lastActivityAt ?? .distantPast) < ($1.lastActivityAt ?? .distantPast)
                    }
                    return $0.id < $1.id
                }
            guard !chats.isEmpty else { return nil }
            return StaleGroup(machine: machine, chats: chats)
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
        recency: SidebarRecency = .all,
        excludedPaneIDs: Set<String> = [],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
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
                    && !excludedPaneIDs.contains($0.id)
                    && recency.includes($0, now: now, calendar: calendar)
            }.map(\.id))
        }

        guard query.isEmpty || workspaceMatches || !matchingTabIDs.isEmpty || !matchingPaneIDs.isEmpty else {
            return nil
        }

        let filteredPanes: [HerdrPane]
        if query.isEmpty || workspaceMatches {
            filteredPanes = workspace.panes.filter {
                !starredIDs.contains($0.id)
                    && !excludedPaneIDs.contains($0.id)
                    && recency.includes($0, now: now, calendar: calendar)
            }
        } else {
            filteredPanes = workspace.panes.filter {
                !starredIDs.contains($0.id)
                    && !excludedPaneIDs.contains($0.id)
                    && (matchingPaneIDs.contains($0.id) || matchingTabIDs.contains($0.scopedTabID))
                    && recency.includes($0, now: now, calendar: calendar)
            }
        }

        let filtersPanes = recency != .all || !excludedPaneIDs.isEmpty

        let sections = sortedTabs.compactMap { tab -> SectionEntry? in
            let chats = filteredPanes
                .filter { $0.scopedTabID == tab.id }
                .sorted { $0.paneID < $1.paneID }
            guard (query.isEmpty && !filtersPanes) || !chats.isEmpty || (!filtersPanes && matchingTabIDs.contains(tab.id)) else { return nil }
            return SectionEntry(
                tab: tab,
                isExpanded: query.isEmpty ? !collapsedTabIDs.contains(tab.id) : true,
                chats: chats
            )
        }
        let looseChats = filteredPanes
            .filter { !tabIDs.contains($0.scopedTabID) }
            .sorted { $0.paneID < $1.paneID }

        guard !filtersPanes || !sections.isEmpty || !looseChats.isEmpty else { return nil }

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
