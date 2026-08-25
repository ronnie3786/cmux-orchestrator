import Testing
@testable import herdr_harness_mac

@Suite("Command palette")
struct CommandPaletteTests {
    @Test("Search covers title, agent, workspace, tab, and machine")
    func searchesEveryVisibleContext() {
        #expect(search("auth") == ["auth"])
        #expect(search("claude") == ["auth"])
        #expect(search("member") == ["pagination"])
        #expect(search("agents") == ["auth"])
        #expect(search("lux") == ["pagination"])
    }

    @Test("Search supports fuzzy subsequences and tokens across fields")
    func fuzzyAndCrossFieldSearch() {
        #expect(search("atrv") == ["auth"])
        #expect(search("codex release") == ["release"])
        #expect(search("claude doximity") == ["auth"])
    }

    @Test("Stronger matches rank first and ties preserve fleet order")
    func deterministicRanking() {
        let exactTitle = entry(id: "title", title: "Codex", agent: "Terminal", order: 2)
        let agentMatch = entry(id: "agent", title: "Background task", agent: "Codex", order: 0)
        let laterAgentMatch = entry(id: "later", title: "Another task", agent: "Codex", order: 1)

        let results = CommandPaletteIndex.search(
            [agentMatch, laterAgentMatch, exactTitle],
            query: "codex"
        )

        #expect(results.map(\.id) == ["title", "agent", "later"])
    }

    @Test("Empty and unmatched queries are predictable")
    func emptyAndUnmatchedQueries() {
        #expect(CommandPaletteIndex.search(entries, query: "   ").map(\.id) == ["auth", "pagination", "release"])
        #expect(CommandPaletteIndex.search(entries, query: "no-such-chat").isEmpty)
    }

    @Test("Keyboard highlight wraps and resets when the query changes")
    func keyboardHighlightWraps() {
        var state = CommandPaletteState(entries: entries)

        state.moveHighlight(by: -1)
        #expect(state.highlightedEntry?.id == "release")

        state.moveHighlight(by: 1)
        #expect(state.highlightedEntry?.id == "auth")

        state.query = "codex"
        state.queryDidChange()
        #expect(state.results.map(\.id) == ["pagination", "release"])
        #expect(state.highlightedEntry?.id == "pagination")
    }

    @Test("Live fleet replacement preserves a highlighted pane when possible")
    func replacementPreservesHighlight() {
        var state = CommandPaletteState(entries: entries)
        state.moveHighlight(by: 1)
        #expect(state.highlightedEntry?.id == "pagination")

        state.replaceEntries([entries[2], entries[1]])

        #expect(state.highlightedEntry?.id == "pagination")
    }

    @Test("Fleet indexing carries tab and machine context into routable entries")
    func buildsFleetEntries() throws {
        let pane = HerdrPane(
            paneID: "w1:p1",
            terminalID: "term-1",
            workspaceID: "w1",
            tabID: "w1:t1",
            focused: false,
            agentStatus: .working,
            revision: 3,
            cwd: "/work/auth",
            foregroundCWD: nil,
            label: nil,
            title: "Review authentication",
            agent: "codex",
            displayAgent: "Codex",
            terminalTitle: nil,
            terminalTitleStripped: nil
        )
        let tab = HerdrTab(
            tabID: "w1:t1",
            workspaceID: "w1",
            number: 1,
            label: "Agents",
            focused: true,
            paneCount: 1,
            agentStatus: .working
        )
        let workspace = HerdrWorkspace(
            workspaceID: "w1",
            number: 1,
            label: "Identity",
            focused: true,
            paneCount: 1,
            tabCount: 1,
            activeTabID: "w1:t1",
            agentStatus: .working,
            tabs: [tab],
            panes: [pane]
        )
        .stamped(machineID: "studio")

        let indexed = CommandPaletteIndex.entries(
            workspaces: [workspace],
            machines: [HerdrMachine(id: "studio", name: "Mac Studio", urlString: "http://localhost")]
        )
        let result = try #require(indexed.first)

        #expect(result.id == "studio|w1:p1")
        #expect(result.tabName == "Agents")
        #expect(result.machineName == "Mac Studio")
        #expect(result.workspaceName == "Identity")
    }

    private var entries: [CommandPaletteEntry] {
        [
            entry(
                id: "auth",
                title: "Auth reducer review",
                agent: "Claude",
                workspace: "iOS Doximity",
                tab: "Agents",
                machine: "MacBook Pro",
                status: .blocked,
                order: 0
            ),
            entry(
                id: "pagination",
                title: "Pagination contract",
                agent: "Codex",
                workspace: "Member API",
                tab: "API",
                machine: "Custom Lux",
                status: .done,
                order: 1
            ),
            entry(
                id: "release",
                title: "Release notes",
                agent: "Codex",
                workspace: "Release Train",
                tab: "Release",
                machine: "MacBook Pro",
                status: .idle,
                order: 2
            ),
        ]
    }

    private func search(_ query: String) -> [String] {
        CommandPaletteIndex.search(entries, query: query).map(\.id)
    }

    private func entry(
        id: String,
        title: String,
        agent: String,
        workspace: String = "Workspace",
        tab: String = "Tab",
        machine: String = "Machine",
        status: AgentStatus = .idle,
        order: Int
    ) -> CommandPaletteEntry {
        CommandPaletteEntry(
            paneID: id,
            title: title,
            agentName: agent,
            workspaceName: workspace,
            workspacePath: "/work/\(workspace)",
            tabName: tab,
            machineName: machine,
            status: status,
            order: order
        )
    }
}
