import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Sidebar tree")
struct SidebarTreeTests {
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
        title: String
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
            terminalTitleStripped: nil
        )
    }
}
