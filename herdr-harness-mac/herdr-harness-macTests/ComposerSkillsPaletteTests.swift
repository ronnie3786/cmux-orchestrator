import Testing
@testable import herdr_harness_mac

/// Every rule the `$`-skills HUD promises, exercised without a view.
@Suite("Composer skills palette")
struct ComposerSkillsPaletteTests {
    // MARK: - Trigger

    @Test("A dollar sign at the start of the draft opens the HUD")
    func triggersAtStartOfDraft() {
        var palette = makePalette()

        palette.textDidChange("$", caret: 1)

        #expect(palette.isVisible)
        #expect(palette.query.isEmpty)
        #expect(palette.matches.map(\.name) == ["swiftui-pro", "self-qa", "release-ios", "handoff"])
    }

    @Test("A dollar sign after whitespace opens the HUD")
    func triggersAfterWhitespace() {
        var palette = makePalette()

        palette.textDidChange("please run $sw", caret: 14)

        #expect(palette.isVisible)
        #expect(palette.query == "sw")
        #expect(palette.matches.map(\.name) == ["swiftui-pro"])
    }

    @Test("A dollar sign after a newline opens the HUD")
    func triggersAfterNewline() {
        var palette = makePalette()

        palette.textDidChange("first line\n$ha", caret: 14)

        #expect(palette.isVisible)
        #expect(palette.matches.map(\.name) == ["handoff"])
    }

    @Test("A dollar sign glued to a word is not a trigger")
    func ignoresMidWordDollarSign() {
        var palette = makePalette()

        palette.textDidChange("USD$sw", caret: 6)

        #expect(!palette.isVisible)
    }

    @Test("Whitespace after the token closes it")
    func whitespaceEndsTheToken() {
        var palette = makePalette()

        palette.textDidChange("$sw", caret: 3)
        #expect(palette.isVisible)

        palette.textDidChange("$sw ", caret: 4)
        #expect(!palette.isVisible)
    }

    @Test("A draft with no dollar sign never opens the HUD")
    func noTriggerWithoutDollarSign() {
        var palette = makePalette()

        palette.textDidChange("just a normal prompt", caret: 20)

        #expect(!palette.isVisible)
        #expect(palette.matches.isEmpty)
    }

    // MARK: - Filtering

    @Test("Filtering is case-insensitive and ranks prefixes above containment")
    func filtersPrefixesFirst() {
        var palette = makePalette()

        palette.textDidChange("$SE", caret: 3)

        // "self-qa" starts with "se" (tier 0, prefix); "release-ios" only
        // contains "se" (tier 1, containment), so it sorts after.
        #expect(palette.matches.map(\.name) == ["self-qa", "release-ios"])
    }

    @Test("Fuzzy matching accepts letters that appear in order")
    func fuzzyMatchesSubsequences() {
        var palette = makePalette()

        palette.textDidChange("$sui", caret: 4)

        #expect(palette.matches.map(\.name) == ["swiftui-pro"])
    }

    @Test("Letters out of order do not match")
    func rejectsOutOfOrderLetters() {
        #expect(!ComposerSkillsPalette.isSubsequence("ius", of: "swiftui-pro"))
        #expect(ComposerSkillsPalette.isSubsequence("sui", of: "swiftui-pro"))
    }

    @Test("Zero matches closes the HUD without nagging")
    func zeroMatchesAutoDismisses() {
        var palette = makePalette()

        palette.textDidChange("$sw", caret: 3)
        #expect(palette.isVisible)

        palette.textDidChange("$swzz", caret: 5)
        #expect(!palette.isVisible)
        #expect(palette.matches.isEmpty)
    }

    @Test("Backspacing out of a zero-match query re-opens the HUD")
    func backspacingReopensAfterZeroMatches() {
        var palette = makePalette()

        palette.textDidChange("$swzz", caret: 5)
        #expect(!palette.isVisible)

        palette.textDidChange("$sw", caret: 3)
        #expect(palette.isVisible)
        #expect(palette.matches.map(\.name) == ["swiftui-pro"])
    }

    @Test("Skills arriving after the trigger fill the open HUD in")
    func lateSkillsPopulateTheHUD() {
        var palette = ComposerSkillsPalette()

        palette.textDidChange("$sw", caret: 3)
        #expect(!palette.isVisible)

        palette.replaceSkills(Self.skills)

        #expect(palette.isVisible)
        #expect(palette.matches.map(\.name) == ["swiftui-pro"])
    }

    @Test("Ranking puts prefix hits first, alphabetically, then containment, then path-only hits")
    func ranksMatchesByStrength() {
        var palette = makePalette()

        palette.textDidChange("$s", caret: 2)

        // self-qa/swiftui-pro start with "s", release-ios contains it, and
        // handoff only reaches it through the skills directory in its path.
        #expect(palette.matches.map(\.name) == ["self-qa", "swiftui-pro", "release-ios", "handoff"])
    }

    @Test("A query that only the file path contains still matches")
    func filtersByPath() {
        var palette = makePalette()

        palette.textDidChange("$claude", caret: 7)

        #expect(palette.matches.map(\.name) == ["release-ios", "self-qa", "swiftui-pro"])
    }

    @Test("Accepting always leaves exactly one trailing space")
    func acceptanceAddsOneTrailingSpace() {
        var palette = makePalette()
        palette.textDidChange("$sw", caret: 3)

        let acceptance = palette.accept()

        #expect(acceptance?.token == "$swiftui-pro ")
        #expect(acceptance?.text.hasSuffix("pro ") == true)
        #expect(acceptance?.text.hasSuffix("pro  ") == false)
    }

    // MARK: - Highlight

    @Test("The top row is highlighted by default")
    func highlightsTopRowByDefault() {
        var palette = makePalette()

        palette.textDidChange("$", caret: 1)

        #expect(palette.highlightedIndex == 0)
        #expect(palette.highlightedSkill?.name == "swiftui-pro")
    }

    @Test("Arrow keys move the highlight and wrap at both ends")
    func highlightWraps() {
        var palette = makePalette()
        palette.textDidChange("$", caret: 1)
        let count = palette.matches.count

        palette.moveHighlight(by: 1)
        #expect(palette.highlightedIndex == 1)

        palette.moveHighlight(by: -1)
        #expect(palette.highlightedIndex == 0)

        palette.moveHighlight(by: -1)
        #expect(palette.highlightedIndex == count - 1)

        palette.moveHighlight(by: 1)
        #expect(palette.highlightedIndex == 0)
    }

    @Test("Re-filtering returns the highlight to the top row")
    func highlightResetsOnRefilter() {
        var palette = makePalette()
        palette.textDidChange("$", caret: 1)
        palette.moveHighlight(by: 2)
        #expect(palette.highlightedIndex == 2)

        palette.textDidChange("$s", caret: 2)

        #expect(palette.highlightedIndex == 0)
    }

    @Test("Hovering a row moves the highlight, and out-of-range rows are ignored")
    func highlightFollowsHover() {
        var palette = makePalette()
        palette.textDidChange("$s", caret: 2)

        palette.highlight(1)
        #expect(palette.highlightedIndex == 1)

        palette.highlight(99)
        #expect(palette.highlightedIndex == 1)
    }

    // MARK: - Selection reset

    @Test("A keystroke that does not change the list keeps the highlight")
    func keepsHighlightWhenTheListDoesNotChange() {
        var palette = makePalette()
        palette.textDidChange("$sk", caret: 3)
        #expect(palette.matches.map(\.name) == ["handoff", "release-ios", "self-qa", "swiftui-pro"])
        palette.moveHighlight(by: 2)
        #expect(palette.highlightedIndex == 2)

        // "sk"/"ski" only match through the skills segment of every path, so
        // the list is identical and the user's row survives.
        palette.textDidChange("$ski", caret: 4)
        #expect(palette.highlightedIndex == 2)
    }

    @Test("A changed list sends the highlight back to the top")
    func resetsHighlightWhenTheListChanges() {
        var palette = makePalette()
        palette.textDidChange("$sk", caret: 3)
        palette.moveHighlight(by: 2)

        palette.textDidChange("$s", caret: 2)

        #expect(palette.highlightedIndex == 0)
    }

    @Test("The HUD reports at most six visible rows")
    func capsVisibleRows() {
        var palette = ComposerSkillsPalette(
            skills: (0..<9).map {
                ProjectSkill(name: "skill-\($0)", skillFilePath: "./s\($0)/SKILL.md", scope: "project")
            }
        )

        palette.textDidChange("$", caret: 1)

        #expect(palette.matches.count == 9)
        #expect(palette.visibleRowCount == ComposerSkillsPalette.maximumVisibleRows)
    }

    // MARK: - Acceptance

    @Test("Accepting replaces the whole token with the skill invocation")
    func acceptRewritesTheToken() {
        var palette = makePalette()
        palette.textDidChange("run $sw", caret: 7)

        let acceptance = palette.accept()

        #expect(acceptance?.token == "$swiftui-pro ")
        #expect(acceptance?.text == "run $swiftui-pro ")
        #expect(acceptance?.caret == 17)
        #expect(!palette.isVisible)
    }

    @Test("Accepting keeps text that follows the token")
    func acceptPreservesTrailingText() {
        var palette = makePalette()
        palette.textDidChange("$ha then stop", caret: 3)

        let acceptance = palette.accept()

        #expect(acceptance?.text == "$handoff  then stop")
    }

    @Test("Accepting a specific row inserts that row")
    func acceptAtIndexInsertsThatRow() {
        var palette = makePalette()
        palette.textDidChange("$s", caret: 2)

        // Prefix hits sort alphabetically, so row 0 is self-qa and row 1 is swiftui-pro.
        let acceptance = palette.accept(at: 1)

        #expect(acceptance?.token == "$swiftui-pro ")
        #expect(acceptance?.text == "$swiftui-pro ")
    }

    @Test("Accepting is impossible while the HUD is hidden")
    func acceptRequiresAVisibleHUD() {
        var palette = makePalette()
        palette.textDidChange("plain prompt", caret: 12)

        #expect(palette.accept() == nil)
        #expect(palette.accept(at: 0) == nil)
    }

    @Test("An accepted token can be followed by a new trigger")
    func acceptClearsDismissalMemory() throws {
        var palette = makePalette()
        palette.textDidChange("$sw", caret: 3)
        let accepted = palette.accept()
        let acceptance = try #require(accepted)

        palette.textDidChange(
            acceptance.text + "$ha",
            caret: acceptance.text.count + 3
        )

        #expect(palette.isVisible)
        #expect(palette.matches.map(\.name) == ["handoff"])
    }

    // MARK: - Dismissal memory

    @Test("Escape hides the HUD and leaves the draft untouched")
    func escapeDismissesWithoutEditing() {
        var palette = makePalette()
        palette.textDidChange("$sw", caret: 3)

        palette.dismiss()

        #expect(!palette.isVisible)
        // Nothing here rewrites text: the composer's draft is only ever changed
        // through `accept`.
        #expect(palette.accept() == nil)
    }

    @Test("A dismissed token stays dismissed while typing into it")
    func dismissedTokenStaysClosedWhileTyping() {
        var palette = makePalette()
        palette.textDidChange("$s", caret: 2)
        palette.dismiss()

        palette.textDidChange("$sw", caret: 3)
        #expect(!palette.isVisible)

        palette.textDidChange("$swi", caret: 4)
        #expect(!palette.isVisible)
    }

    @Test("Backspacing back into a dismissed token does not re-open it")
    func dismissedTokenStaysClosedWhileBackspacing() {
        var palette = makePalette()
        palette.textDidChange("$swi", caret: 4)
        palette.dismiss()

        palette.textDidChange("$sw", caret: 3)
        #expect(!palette.isVisible)

        palette.textDidChange("$", caret: 1)
        #expect(!palette.isVisible)
    }

    @Test("A space dismisses the token, and undoing the space does not revive it")
    func spaceDismissSurvivesBackspace() {
        var palette = makePalette()
        palette.textDidChange("$sw", caret: 3)

        // The composer dismisses first, then lets the space type itself.
        palette.dismiss()
        palette.textDidChange("$sw ", caret: 4)
        #expect(!palette.isVisible)

        palette.textDidChange("$sw", caret: 3)
        #expect(!palette.isVisible)
    }

    @Test("A newly typed dollar sign re-triggers after a dismissal")
    func newTokenReopensAfterDismissal() {
        var palette = makePalette()
        palette.textDidChange("$sw", caret: 3)
        palette.dismiss()

        palette.textDidChange("$sw $ha", caret: 7)

        #expect(palette.isVisible)
        #expect(palette.matches.map(\.name) == ["handoff"])
    }

    @Test("Deleting the dismissed dollar sign forgets the dismissal")
    func deletingTheTokenForgetsTheDismissal() {
        var palette = makePalette()
        palette.textDidChange("$sw", caret: 3)
        palette.dismiss()

        palette.textDidChange("", caret: 0)
        palette.textDidChange("$sw", caret: 3)

        #expect(palette.isVisible)
    }

    @Test("Dismissing without remembering lets the same token re-open")
    func dismissWithoutMemoryReopens() {
        var palette = makePalette()
        palette.textDidChange("$sw", caret: 3)

        palette.dismiss(remembersToken: false)
        #expect(!palette.isVisible)

        palette.textDidChange("$swi", caret: 4)
        #expect(palette.isVisible)
    }

    @Test("Dismissing a hidden HUD records nothing")
    func dismissingWhileHiddenIsInert() {
        var palette = makePalette()

        palette.dismiss()
        palette.textDidChange("$sw", caret: 3)

        #expect(palette.isVisible)
    }

    // MARK: - Token boundary rule

    @Test("Token detection follows the boundary rule exactly")
    func detectsTokenStart() {
        #expect(tokenStart("$", caret: 1) == 0)
        #expect(tokenStart("  $ab", caret: 5) == 2)
        #expect(tokenStart("a\n$z", caret: 4) == 2)
    }

    @Test("Token detection refuses non-boundaries and out-of-range carets")
    func refusesNonBoundaries() {
        #expect(tokenStart("a$b", caret: 3) == nil)
        #expect(tokenStart("$a b", caret: 4) == nil)
        #expect(tokenStart("no dollars", caret: 10) == nil)
        #expect(tokenStart("$a", caret: 0) == nil)
        #expect(tokenStart("$a", caret: 9) == nil)
    }

    // MARK: - Filter algorithm

    @Test("A skipping subsequence finds the skill the reference app promises")
    func findsSkippingSubsequences() {
        #expect(names("rjt") == ["run-jira-tests"])
    }

    @Test("A hyphenated query is three tokens, not one")
    func tokenizesBoundaries() {
        #expect(ComposerSkillsPalette.tokens(in: "ios-pr-review") == ["ios", "pr", "review"])
        #expect(ComposerSkillsPalette.tokens(in: "Run.Jira:Tests") == ["run", "jira", "tests"])
        // release-ios has ios, but neither pr nor review. Every token must land.
        #expect(names("ios-pr-review") == ["ios-pr-review"])
    }

    @Test("A symbol-only query falls back to a plain substring match")
    func filtersSymbolOnlyQueries() {
        // Hyphenated names rank together alphabetically; handoff only reaches
        // the tier through agent-registry in its path.
        #expect(names("-") == ["ios-pr-review", "release-ios", "run-jira-tests", "handoff"])
        #expect(names("…").isEmpty)
    }

    @Test("Ranking walks prefix, containment, subsequence, then path")
    func ranksEachMatchTier() {
        #expect(names("re") == ["release-ios", "ios-pr-review", "run-jira-tests", "handoff"])
        #expect(ComposerSkillsPalette.rank(Self.algorithmSkills[2], tokens: ["re"]) == 0)
        #expect(ComposerSkillsPalette.rank(Self.algorithmSkills[1], tokens: ["re"]) == 1)
        #expect(ComposerSkillsPalette.rank(Self.algorithmSkills[0], tokens: ["re"]) == 2)
        #expect(ComposerSkillsPalette.rank(Self.algorithmSkills[3], tokens: ["re"]) == 3)
    }

    @Test("An empty query keeps the server's order")
    func keepsServerOrderForEmptyQueries() {
        #expect(names("") == Self.algorithmSkills.map(\.name))
    }

    @Test("Matching is case-insensitive")
    func matchesIgnoringCase() {
        #expect(names("IOS-PR") == ["ios-pr-review"])
    }

    private func tokenStart(_ text: String, caret: Int) -> Int? {
        ComposerSkillsPalette.tokenStart(in: Array(text), caret: caret)
    }

    private func names(_ query: String) -> [String] {
        ComposerSkillsPalette.filter(Self.algorithmSkills, query: query).map(\.name)
    }

    // MARK: - Fixtures

    private static let skills = [
        ProjectSkill(name: "swiftui-pro", skillFilePath: "./.claude/skills/swiftui-pro/SKILL.md", scope: "project"),
        ProjectSkill(name: "self-qa", skillFilePath: "./.claude/skills/self-qa/SKILL.md", scope: "project"),
        ProjectSkill(name: "release-ios", skillFilePath: "./.claude/skills/release-ios/SKILL.md", scope: "project"),
        ProjectSkill(name: "handoff", skillFilePath: "~/.codex/skills/handoff/SKILL.md", scope: "user"),
    ]

    private static let algorithmSkills = [
        ProjectSkill(name: "run-jira-tests", skillFilePath: "./.claude/skills/run-jira-tests/SKILL.md", scope: "project"),
        ProjectSkill(name: "ios-pr-review", skillFilePath: "./.claude/skills/ios-pr-review/SKILL.md", scope: "project"),
        ProjectSkill(name: "release-ios", skillFilePath: "./.claude/skills/release-ios/SKILL.md", scope: "project"),
        ProjectSkill(name: "handoff", skillFilePath: "~/.codex/skills/agent-registry/handoff/SKILL.md", scope: "user"),
    ]

    private func makePalette() -> ComposerSkillsPalette {
        ComposerSkillsPalette(skills: Self.skills)
    }
}
