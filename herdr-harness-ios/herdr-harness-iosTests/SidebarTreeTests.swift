import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Sidebar tree")
struct SidebarTreeTests {
    /// 2025-01-01T12:00:00Z, a Wednesday.
    private let now = Date(timeIntervalSince1970: 1_735_732_800)

    /// Pinned so the week window is the same on every machine.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        calendar.firstWeekday = 1
        return calendar
    }()

    @Test("Builds the full workspace tree in deterministic order")
    func buildsFullTree() {
        let tree = SidebarTree.build(
            workspaces: workspaces,
            query: "",
            collapsedWorkspaceIDs: []
        )

        #expect(tree.map(\.id) == ["w1", "w2", "w3"])
        #expect(tree.allSatisfy { $0.isExpanded })
        #expect(tree[0].sections.map(\.id) == ["w1:t1", "w1:t2"])
        #expect(tree[0].sections[0].chats.map(\.id) == ["w1:p1", "w1:p2"])
        #expect(tree[0].sections[1].chats.map(\.id) == ["w1:p3"])
        #expect(tree[0].looseChats.isEmpty)
    }

    @Test("Today keeps only panes active today")
    func todayRecencyFiltersPanesByActivityDay() {
        let tabs = [tab(id: "recent:t1", workspaceID: "recent", number: 1, label: "Today", paneCount: 3)]
        let panes = [
            pane(id: "recent:p1", workspaceID: "recent", tabID: "recent:t1", title: "Today", firstSeenAt: now),
            pane(id: "recent:p2", workspaceID: "recent", tabID: "recent:t1", title: "Old", firstSeenAt: now.addingTimeInterval(-3 * 86_400)),
            pane(id: "recent:p3", workspaceID: "recent", tabID: "recent:t1", title: "Unknown"),
        ]

        let tree = SidebarTree.build(
            workspaces: [workspace(id: "recent", number: 1, label: "Recent", tabs: tabs, panes: panes)],
            query: "",
            collapsedWorkspaceIDs: [],
            recency: .today,
            now: now,
            calendar: calendar
        )

        #expect(tree[0].sections[0].chats.map(\.id) == ["recent:p1"])
    }

    /// The filter reads `lastActivityAt ?? firstSeenAt`, so "today" means worked
    /// on today rather than created today.
    @Test("Today prefers last activity over a stale first-seen date")
    func todayRecencyPrefersLastActivity() {
        let tabs = [tab(id: "touched:t1", workspaceID: "touched", number: 1, label: "Touched", paneCount: 2)]
        let panes = [
            pane(
                id: "touched:p1",
                workspaceID: "touched",
                tabID: "touched:t1",
                title: "Opened last week, touched today",
                firstSeenAt: now.addingTimeInterval(-6 * 86_400),
                lastActivityAt: now
            ),
            pane(
                id: "touched:p2",
                workspaceID: "touched",
                tabID: "touched:t1",
                title: "Opened today, untouched since",
                firstSeenAt: now,
                lastActivityAt: now.addingTimeInterval(-3 * 86_400)
            ),
        ]

        let tree = SidebarTree.build(
            workspaces: [workspace(id: "touched", number: 1, label: "Touched", tabs: tabs, panes: panes)],
            query: "",
            collapsedWorkspaceIDs: [],
            recency: .today,
            now: now,
            calendar: calendar
        )

        #expect(tree[0].sections[0].chats.map(\.id) == ["touched:p1"])
    }

    @Test("This week keeps panes from the current week only")
    func thisWeekRecencyKeepsThisWeeksPanes() {
        let tabs = [tab(id: "week:t1", workspaceID: "week", number: 1, label: "Week", paneCount: 2)]
        let panes = [
            pane(id: "week:p1", workspaceID: "week", tabID: "week:t1", title: "Three days ago", lastActivityAt: now.addingTimeInterval(-3 * 86_400)),
            pane(id: "week:p2", workspaceID: "week", tabID: "week:t1", title: "Ten days ago", lastActivityAt: now.addingTimeInterval(-10 * 86_400)),
        ]

        let tree = SidebarTree.build(
            workspaces: [workspace(id: "week", number: 1, label: "Week", tabs: tabs, panes: panes)],
            query: "",
            collapsedWorkspaceIDs: [],
            recency: .thisWeek,
            now: now,
            calendar: calendar
        )

        #expect(tree[0].sections[0].chats.map(\.id) == ["week:p1"])
    }

    @Test("Today filtering applies to starred groups")
    func todayRecencyFiltersStarredGroups() {
        let tabs = [tab(id: "starred:t1", workspaceID: "starred", number: 1, label: "Today", paneCount: 2)]
        let panes = [
            pane(id: "starred:p1", workspaceID: "starred", tabID: "starred:t1", title: "Today", firstSeenAt: now),
            pane(id: "starred:p2", workspaceID: "starred", tabID: "starred:t1", title: "Old", firstSeenAt: now.addingTimeInterval(-3 * 86_400)),
        ]
        let groups = SidebarTree.starredGroups(
            workspaces: [workspace(id: "starred", number: 1, label: "Starred", tabs: tabs, panes: panes)],
            query: "",
            starredIDs: ["starred:p1", "starred:p2"],
            recency: .today,
            now: now,
            calendar: calendar
        )

        #expect(groups[0].chats.map(\.id) == ["starred:p1"])
    }

    @Test("Today filtering drops empty tabs and workspaces")
    func todayRecencyDropsEmptyTabsAndWorkspaces() {
        let mixedTabs = [
            tab(id: "mixed:t1", workspaceID: "mixed", number: 1, label: "Old", paneCount: 1),
            tab(id: "mixed:t2", workspaceID: "mixed", number: 2, label: "Today", paneCount: 1),
        ]
        let mixedPanes = [
            pane(id: "mixed:p1", workspaceID: "mixed", tabID: "mixed:t1", title: "Old", firstSeenAt: now.addingTimeInterval(-3 * 86_400)),
            pane(id: "mixed:p2", workspaceID: "mixed", tabID: "mixed:t2", title: "Today", firstSeenAt: now),
        ]
        let oldTabs = [tab(id: "old:t1", workspaceID: "old", number: 1, label: "Old", paneCount: 1)]
        let oldPanes = [
            pane(id: "old:p1", workspaceID: "old", tabID: "old:t1", title: "Old", firstSeenAt: now.addingTimeInterval(-3 * 86_400)),
        ]

        let tree = SidebarTree.build(
            workspaces: [
                workspace(id: "mixed", number: 1, label: "Mixed", tabs: mixedTabs, panes: mixedPanes),
                workspace(id: "old", number: 2, label: "Old", tabs: oldTabs, panes: oldPanes),
            ],
            query: "",
            collapsedWorkspaceIDs: [],
            recency: .today,
            now: now,
            calendar: calendar
        )

        #expect(tree.map(\.id) == ["mixed"])
        #expect(tree[0].sections.map(\.id) == ["mixed:t2"])
    }

    @Test("All preserves dated and undated panes alike")
    func allRecencyKeepsAllPanes() {
        let tabs = [tab(id: "all:t1", workspaceID: "all", number: 1, label: "All", paneCount: 3)]
        let panes = [
            pane(id: "all:p1", workspaceID: "all", tabID: "all:t1", title: "Today", firstSeenAt: now),
            pane(id: "all:p2", workspaceID: "all", tabID: "all:t1", title: "Old", firstSeenAt: now.addingTimeInterval(-3 * 86_400)),
            pane(id: "all:p3", workspaceID: "all", tabID: "all:t1", title: "Unknown"),
        ]
        let tree = SidebarTree.build(
            workspaces: [workspace(id: "all", number: 1, label: "All", tabs: tabs, panes: panes)],
            query: "",
            collapsedWorkspaceIDs: [],
            recency: .all,
            now: now,
            calendar: calendar
        )

        #expect(tree[0].sections[0].chats.map(\.id) == ["all:p1", "all:p2", "all:p3"])
    }

    @Test("Keeps collapsed workspaces collapsed outside search")
    func honorsCollapsedWorkspaces() {
        let tree = SidebarTree.build(
            workspaces: workspaces,
            query: "",
            collapsedWorkspaceIDs: ["w1"]
        )

        #expect(!tree[0].isExpanded)
        #expect(tree[1].isExpanded)
        #expect(tree[2].isExpanded)
    }

    @Test("Keeps collapsed tab sections collapsed outside search")
    func honorsCollapsedTabs() {
        let tree = SidebarTree.build(
            workspaces: workspaces,
            query: "",
            collapsedWorkspaceIDs: [],
            collapsedTabIDs: ["w1:t1"]
        )

        #expect(!tree[0].sections[0].isExpanded)
        #expect(tree[0].sections[1].isExpanded)
    }

    @Test("Searching force-expands collapsed tab sections")
    func tabSearchForcesExpansion() {
        let tree = SidebarTree.build(
            workspaces: workspaces,
            query: "Auth",
            collapsedWorkspaceIDs: [],
            collapsedTabIDs: ["w1:t1"]
        )

        #expect(tree[0].sections[0].isExpanded)
    }

    @Test("Filters chats by pane title and expands matching projects")
    func filtersByPaneTitle() {
        let tree = SidebarTree.build(
            workspaces: workspaces,
            query: "Auth",
            collapsedWorkspaceIDs: ["w1"]
        )

        #expect(tree.map(\.id) == ["w1"])
        #expect(tree[0].isExpanded)
        #expect(tree[0].sections.map(\.id) == ["w1:t1"])
        #expect(tree[0].sections[0].chats.map(\.id) == ["w1:p2"])
    }

    @Test("Query matching is case-insensitive")
    func matchingIsCaseInsensitive() {
        let tree = SidebarTree.build(
            workspaces: workspaces,
            query: "auth",
            collapsedWorkspaceIDs: []
        )

        #expect(tree.map(\.id) == ["w1"])
        #expect(tree[0].sections[0].chats.map(\.id) == ["w1:p2"])
    }

    @Test("Whitespace-only query behaves like an empty query")
    func whitespaceOnlyQueryBehavesAsEmpty() {
        let tree = SidebarTree.build(
            workspaces: workspaces,
            query: "   ",
            collapsedWorkspaceIDs: ["w1"]
        )

        #expect(tree.map(\.id) == ["w1", "w2", "w3"])
        #expect(!tree[0].isExpanded)
    }

    @Test("Query is trimmed before matching")
    func queryIsTrimmedBeforeMatching() {
        let tree = SidebarTree.build(
            workspaces: workspaces,
            query: "  Auth ",
            collapsedWorkspaceIDs: []
        )

        #expect(tree.map(\.id) == ["w1"])
        #expect(tree[0].sections[0].chats.map(\.id) == ["w1:p2"])
    }

    @Test("Workspace matches retain all of their chats")
    func workspaceMatchRetainsAllChats() throws {
        let tree = SidebarTree.build(
            workspaces: workspaces,
            query: "Member",
            collapsedWorkspaceIDs: []
        )

        let w2Entry = try #require(tree.first(where: { $0.id == "w2" }))
        #expect(w2Entry.sections.map(\.id) == ["w2:t1"])
        #expect(w2Entry.sections[0].chats.map(\.id) == ["w2:p1", "w2:p2"])
    }

    @Test("Tab matches retain all chats in the matching tab")
    func tabMatchRetainsTabChats() {
        let tree = SidebarTree.build(
            workspaces: workspaces,
            query: "Tests",
            collapsedWorkspaceIDs: []
        )

        #expect(tree.map(\.id) == ["w1"])
        #expect(tree[0].sections.map(\.id) == ["w1:t2"])
        #expect(tree[0].sections[0].chats.map(\.id) == ["w1:p3"])
    }

    @Test("Treats panes without tabs as loose chats")
    func buildsLooseChatsWithoutTabs() {
        let panes = [
            pane(id: "loose:p2", workspaceID: "loose", tabID: "missing", title: "Second"),
            pane(id: "loose:p1", workspaceID: "loose", tabID: "missing", title: "First"),
        ]
        let workspace = HerdrWorkspace(
            workspaceID: "loose",
            number: 1,
            label: "Loose",
            focused: false,
            paneCount: panes.count,
            tabCount: 0,
            activeTabID: "",
            agentStatus: .idle,
            panes: panes
        )

        let tree = SidebarTree.build(
            workspaces: [workspace],
            query: "",
            collapsedWorkspaceIDs: []
        )

        #expect(tree[0].sections.isEmpty)
        #expect(tree[0].looseChats.map(\.id) == ["loose:p1", "loose:p2"])
    }

    @Test("Excludes starred chats from workspace sections")
    func excludesStarredChatsFromTree() {
        let tree = SidebarTree.build(
            workspaces: workspaces,
            query: "",
            collapsedWorkspaceIDs: [],
            starredIDs: ["w1:p2"]
        )

        #expect(tree[0].sections[0].chats.map(\.id) == ["w1:p1"])
        #expect(tree[0].sections[1].chats.map(\.id) == ["w1:p3"])
    }

    @Test("Builds and filters starred groups across workspaces")
    func buildsStarredGroups() {
        let starredIDs: Set<String> = ["w2:p1", "w1:p2"]

        let allStarred = SidebarTree.starredGroups(
            workspaces: workspaces,
            query: "",
            starredIDs: starredIDs
        )
        #expect(allStarred.map(\.id) == ["starred:w1", "starred:w2"])
        #expect(allStarred[0].chats.map(\.id) == ["w1:p2"])
        #expect(allStarred[1].chats.map(\.id) == ["w2:p1"])

        let matchingStarred = SidebarTree.starredGroups(
            workspaces: workspaces,
            query: "Auth",
            starredIDs: starredIDs
        )
        #expect(matchingStarred.map(\.id) == ["starred:w1"])
        #expect(matchingStarred[0].chats.map(\.id) == ["w1:p2"])
    }

    @Test("Orders starred groups and chats deterministically")
    func ordersStarredGroupsAndChats() {
        let groups = SidebarTree.starredGroups(
            workspaces: workspaces,
            query: "",
            starredIDs: ["w3:p1", "w1:p3", "w1:p1"]
        )

        #expect(groups.map(\.id) == ["starred:w1", "starred:w3"])
        #expect(groups[0].chats.map(\.id) == ["w1:p1", "w1:p3"])
    }

    @Test("Omits workspaces without matching starred chats")
    func omitsWorkspacesWithoutMatchingStarredChats() {
        let noMatches = SidebarTree.starredGroups(
            workspaces: workspaces,
            query: "",
            starredIDs: ["nonexistent"]
        )
        #expect(noMatches.isEmpty)

        let oneWorkspace = SidebarTree.starredGroups(
            workspaces: workspaces,
            query: "",
            starredIDs: ["w3:p1"]
        )
        #expect(oneWorkspace.map(\.id) == ["starred:w3"])
        #expect(oneWorkspace[0].chats.map(\.id) == ["w3:p1"])
    }

    @Test("Filters starred chats within groups by pane title")
    func filtersStarredChatsWithinGroupsByPaneTitle() {
        let groups = SidebarTree.starredGroups(
            workspaces: workspaces,
            query: "  member  ",
            starredIDs: ["w1:p1", "w1:p2", "w2:p1"]
        )

        #expect(groups.map(\.id) == ["starred:w1"])
        #expect(groups[0].chats.map(\.id) == ["w1:p1"])
    }

    @Test("Machine groups keep machine-list order and include empty machines")
    func machineGroupsHonorMachineOrder() {
        let first = HerdrMachine(id: "first", name: "First", urlString: "https://first.example.com")
        let second = HerdrMachine(id: "second", name: "Second", urlString: "https://second.example.com")
        let empty = HerdrMachine(id: "empty", name: "Empty", urlString: "https://empty.example.com")
        let groups = SidebarTree.machineGroups(
            machines: [second, empty, first],
            states: ["first": .live, "second": .failed],
            workspaces: [workspaceOne.stamped(machineID: "first"), workspaceTwo.stamped(machineID: "second")],
            query: "",
            collapsedMachineIDs: ["second"],
            collapsedWorkspaceIDs: []
        )

        #expect(groups.map(\.id) == ["machine:second", "machine:empty", "machine:first"])
        #expect(!groups[0].isExpanded)
        #expect(groups[1].isExpanded)
        #expect(groups[1].entries.isEmpty)
        #expect(groups[0].state == .failed)
    }

    @Test("Searching force-expands collapsed machine groups")
    func machineGroupSearchForcesExpansion() {
        let machine = HerdrMachine(id: "one", name: "One", urlString: "https://one.example.com")
        let groups = SidebarTree.machineGroups(
            machines: [machine],
            states: [:],
            workspaces: [workspaceOne.stamped(machineID: "one")],
            query: "auth",
            collapsedMachineIDs: ["one"],
            collapsedWorkspaceIDs: []
        )

        #expect(groups.count == 1)
        #expect(groups[0].isExpanded)
        #expect(groups[0].entries.count == 1)
    }

    @Test("Machine groups and nested workspace IDs remain unique across raw ID collisions")
    func machineGroupsUseScopedIDs() {
        let first = HerdrMachine(id: "one", name: "One", urlString: "https://one.example.com")
        let second = HerdrMachine(id: "two", name: "Two", urlString: "https://two.example.com")
        let groups = SidebarTree.machineGroups(
            machines: [first, second],
            states: [:],
            workspaces: [workspaceOne.stamped(machineID: "one"), workspaceOne.stamped(machineID: "two")],
            query: "",
            collapsedMachineIDs: [],
            collapsedWorkspaceIDs: []
        )

        #expect(groups.map(\.id) == ["machine:one", "machine:two"])
        #expect(groups[0].entries[0].id == "one|w1")
        #expect(groups[1].entries[0].id == "two|w1")
        #expect(groups[0].entries[0].id != groups[1].entries[0].id)
    }

    @Test("Starred groups sort by machine order then workspace number")
    func starredGroupsHonorMachineOrder() {
        let first = HerdrMachine(id: "one", name: "One", urlString: "https://one.example.com")
        let second = HerdrMachine(id: "two", name: "Two", urlString: "https://two.example.com")
        let firstW1 = workspaceOne.stamped(machineID: "one")
        let firstW2 = workspaceTwo.stamped(machineID: "one")
        let secondW1 = workspaceOne.stamped(machineID: "two")
        let groups = SidebarTree.starredGroups(
            workspaces: [firstW2, secondW1, firstW1],
            query: "",
            starredIDs: ["one|w1:p1", "one|w2:p1", "two|w1:p1"],
            machines: [second, first]
        )

        #expect(groups.map(\.id) == ["starred:two|w1", "starred:one|w1", "starred:one|w2"])
        #expect(Set(groups.map(\.id)).count == 3)
    }

    @Test("A single machine still produces one machine group")
    func singleMachineStillProducesGroup() {
        let machine = HerdrMachine(id: "one", name: "One", urlString: "https://one.example.com")
        let groups = SidebarTree.machineGroups(
            machines: [machine],
            states: [:],
            workspaces: [workspaceOne.stamped(machineID: "one")],
            query: "",
            collapsedMachineIDs: [],
            collapsedWorkspaceIDs: []
        )
        #expect(groups.count == 1)
    }

    @Test("Stamped workspaces keep panes under their tabs")
    func stampedWorkspaceKeepsPanesUnderTheirTabs() {
        let stamped = workspaceOne.stamped(machineID: "m1")
        let tree = SidebarTree.build(
            workspaces: [stamped],
            query: "",
            collapsedWorkspaceIDs: []
        )

        #expect(tree[0].sections.map(\.id) == ["m1|w1:t1", "m1|w1:t2"])
        #expect(tree[0].sections[0].chats.map(\.id) == ["m1|w1:p1", "m1|w1:p2"])
        #expect(tree[0].sections[1].chats.map(\.id) == ["m1|w1:p3"])
        #expect(tree[0].looseChats.isEmpty)
    }

    @Test("Stamped workspaces still collect panes without matching tabs")
    func stampedWorkspaceStillCollectsLoosePanes() {
        let tabs = [tab(id: "loose:t1", workspaceID: "loose", number: 1, label: "Primary", paneCount: 1)]
        let panes = [
            pane(id: "loose:p1", workspaceID: "loose", tabID: "loose:t1", title: "Assigned"),
            pane(id: "loose:p2", workspaceID: "loose", tabID: "missing", title: "Loose"),
        ]
        let stamped = workspace(
            id: "loose",
            number: 1,
            label: "Loose",
            tabs: tabs,
            panes: panes
        )
        .stamped(machineID: "m1")

        let tree = SidebarTree.build(
            workspaces: [stamped],
            query: "",
            collapsedWorkspaceIDs: []
        )

        #expect(tree[0].sections[0].chats.map(\.id) == ["m1|loose:p1"])
        #expect(tree[0].looseChats.map(\.id) == ["m1|loose:p2"])
    }

    @Test("Stamped tab label searches retain the tab's chats")
    func stampedTabLabelSearchRetainsTabChats() {
        let tree = SidebarTree.build(
            workspaces: [workspaceOne.stamped(machineID: "m1")],
            query: "Tests",
            collapsedWorkspaceIDs: []
        )

        #expect(tree[0].sections.map(\.id) == ["m1|w1:t2"])
        #expect(tree[0].sections[0].chats.map(\.id) == ["m1|w1:p3"])
    }

    private var workspaces: [HerdrWorkspace] {
        [workspaceThree, workspaceOne, workspaceTwo]
    }

    private var workspaceOne: HerdrWorkspace {
        let tabs = [
            tab(id: "w1:t2", workspaceID: "w1", number: 2, label: "Tests", paneCount: 1),
            tab(id: "w1:t1", workspaceID: "w1", number: 1, label: "Agents", paneCount: 2),
        ]
        let panes = [
            pane(id: "w1:p2", workspaceID: "w1", tabID: "w1:t1", title: "Auth reducer review"),
            pane(id: "w1:p1", workspaceID: "w1", tabID: "w1:t1", title: "Refine member profile"),
            pane(id: "w1:p3", workspaceID: "w1", tabID: "w1:t2", title: "Unit tests"),
        ]
        return workspace(
            id: "w1",
            number: 1,
            label: "iOS Doximity",
            tabs: tabs,
            panes: panes
        )
    }

    private var workspaceTwo: HerdrWorkspace {
        let tabs = [tab(id: "w2:t1", workspaceID: "w2", number: 1, label: "API", paneCount: 2)]
        let panes = [
            pane(id: "w2:p1", workspaceID: "w2", tabID: "w2:t1", title: "Pagination contract"),
            pane(id: "w2:p2", workspaceID: "w2", tabID: "w2:t1", title: "GraphQL smoke test"),
        ]
        return workspace(
            id: "w2",
            number: 2,
            label: "Member API",
            tabs: tabs,
            panes: panes
        )
    }

    private var workspaceThree: HerdrWorkspace {
        let tabs = [tab(id: "w3:t1", workspaceID: "w3", number: 1, label: "Release", paneCount: 1)]
        let panes = [
            pane(id: "w3:p1", workspaceID: "w3", tabID: "w3:t1", title: "Release notes"),
        ]
        return workspace(
            id: "w3",
            number: 3,
            label: "Release Train",
            tabs: tabs,
            panes: panes
        )
    }

    private func workspace(
        id: String,
        number: Int,
        label: String,
        tabs: [HerdrTab],
        panes: [HerdrPane]
    ) -> HerdrWorkspace {
        HerdrWorkspace(
            workspaceID: id,
            number: number,
            label: label,
            focused: false,
            paneCount: panes.count,
            tabCount: tabs.count,
            activeTabID: tabs.first?.id ?? "",
            agentStatus: .idle,
            tabs: tabs,
            panes: panes
        )
    }

    private func tab(
        id: String,
        workspaceID: String,
        number: Int,
        label: String,
        paneCount: Int
    ) -> HerdrTab {
        HerdrTab(
            tabID: id,
            workspaceID: workspaceID,
            number: number,
            label: label,
            focused: false,
            paneCount: paneCount,
            agentStatus: .idle
        )
    }

    private func pane(
        id: String,
        workspaceID: String,
        tabID: String,
        title: String,
        firstSeenAt: Date? = nil,
        lastActivityAt: Date? = nil
    ) -> HerdrPane {
        HerdrPane(
            paneID: id,
            terminalID: id,
            workspaceID: workspaceID,
            tabID: tabID,
            focused: false,
            agentStatus: .idle,
            revision: 0,
            cwd: nil,
            foregroundCWD: nil,
            label: nil,
            title: title,
            agent: nil,
            displayAgent: nil,
            terminalTitle: nil,
            terminalTitleStripped: nil,
            firstSeenAt: firstSeenAt,
            lastActivityAt: lastActivityAt
        )
    }
}
