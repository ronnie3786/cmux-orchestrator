import Foundation

/// The state machine behind the composer's `$`-skills HUD.
///
/// Deliberately UI-free: the composer owns the text field, the key presses and
/// the floating card, and hands every edit here. Keeping the rules in one
/// value type is what makes the fiddly parts — the token-boundary trigger, the
/// wrap-around highlight, and the memory of a token the user already waved off
/// — testable without rendering anything.
///
/// Caret positions are character offsets into the draft. `TextField` on macOS
/// exposes no selection binding, so the composer passes `draft.count`; the API
/// still takes the caret explicitly so the boundary rule is exact and so a
/// future caret-aware field needs no changes here.
struct ComposerSkillsPalette: Equatable, Sendable {
    /// How many rows the HUD shows before it starts scrolling.
    static let maximumVisibleRows = 6
    /// The character that opens the HUD. Matches `SkillInsertionStyle.codexCLI`,
    /// which is also what an accepted row inserts.
    static let trigger: Character = "$"

    /// The result of accepting a row: the whole draft, rewritten.
    struct Acceptance: Equatable, Sendable {
        var text: String
        var caret: Int
        var token: String
    }

    private(set) var skills: [ProjectSkill]
    private(set) var isVisible = false
    private(set) var matches: [ProjectSkill] = []
    private(set) var highlightedIndex = 0
    private(set) var query = ""

    /// Offset of the `$` that opened the HUD.
    private var tokenStart: Int?
    /// Offset of the `$` the user explicitly waved off. It survives further
    /// typing and backspacing inside the same token, and only expires when that
    /// `$` stops existing.
    private var dismissedTokenStart: Int?
    private var text = ""
    private var caret = 0

    init(skills: [ProjectSkill] = []) {
        self.skills = skills
    }

    var highlightedSkill: ProjectSkill? {
        guard isVisible, matches.indices.contains(highlightedIndex) else { return nil }
        return matches[highlightedIndex]
    }

    /// Row count the HUD should size itself to before scrolling.
    var visibleRowCount: Int {
        min(matches.count, Self.maximumVisibleRows)
    }

    // MARK: - Input

    /// Feeds the palette a new draft. The single entry point for every edit,
    /// including the composer rewriting the draft after an acceptance.
    mutating func textDidChange(_ text: String, caret: Int) {
        self.text = text
        self.caret = max(0, min(caret, text.count))
        reevaluate()
    }

    /// Installs a freshly fetched skill list and re-runs the current filter, so
    /// a HUD that opened before the workspace answered still fills in.
    mutating func replaceSkills(_ skills: [ProjectSkill]) {
        self.skills = skills
        reevaluate()
    }

    // MARK: - Highlight

    /// Moves the highlight, wrapping at both ends.
    mutating func moveHighlight(by delta: Int) {
        guard isVisible, !matches.isEmpty else { return }
        let count = matches.count
        highlightedIndex = ((highlightedIndex + delta) % count + count) % count
    }

    /// Points the highlight at a specific row — the pointer hovering a row.
    mutating func highlight(_ index: Int) {
        guard isVisible, matches.indices.contains(index) else { return }
        highlightedIndex = index
    }

    // MARK: - Dismissal

    /// Escape, Space, and losing focus all land here.
    ///
    /// `remembersToken` is what stops the same `$token` springing back on the
    /// next keystroke: the user said "not a skill", and backspacing inside that
    /// token must not argue with them. A brand new `$` always re-triggers.
    mutating func dismiss(remembersToken: Bool = true) {
        guard isVisible else { return }
        if remembersToken { dismissedTokenStart = tokenStart }
        close()
    }

    // MARK: - Acceptance

    /// Accepts the highlighted row.
    mutating func accept() -> Acceptance? {
        accept(at: highlightedIndex)
    }

    /// Accepts a specific row — Enter/Tab on the highlight, or a click.
    ///
    /// Replaces the whole `$query` token with `$name ` (the Codex CLI
    /// invocation the skills browser already inserts, plus the space that ends
    /// the token) and returns the rewritten draft for the composer to apply.
    mutating func accept(at index: Int) -> Acceptance? {
        guard isVisible, matches.indices.contains(index), let start = tokenStart else { return nil }
        let token = SkillInsertionStyle.codexCLI.token(for: matches[index]) + " "
        let tokenCharacters = Array(token)
        var characters = Array(text)
        characters.replaceSubrange(start..<caret, with: tokenCharacters)
        let updatedText = String(characters)
        let updatedCaret = start + tokenCharacters.count

        dismissedTokenStart = nil
        close()
        text = updatedText
        caret = updatedCaret
        return Acceptance(text: updatedText, caret: updatedCaret, token: token)
    }

    // MARK: - Rules

    /// Finds the `$` that owns the caret, or `nil` when there is no live token.
    ///
    /// `$` only counts at a token boundary — the start of the draft or right
    /// after whitespace — so `usd$5` and `git commit$` mid-word never trigger,
    /// and any whitespace between the `$` and the caret ends the token.
    static func tokenStart(in characters: [Character], caret: Int) -> Int? {
        guard caret >= 1, caret <= characters.count else { return nil }
        var index = caret - 1
        while index >= 0 {
            let character = characters[index]
            if character == trigger {
                guard index == 0 || characters[index - 1].isWhitespace else { return nil }
                return index
            }
            if character.isWhitespace { return nil }
            index -= 1
        }
        return nil
    }

    /// Case-insensitive fuzzy-prefix filter on the skill name: exact prefixes
    /// first, then names that contain the query letters in order.
    static func filter(_ skills: [ProjectSkill], query: String) -> [ProjectSkill] {
        guard !query.isEmpty else { return skills }
        let needle = query.lowercased()
        var prefixed: [ProjectSkill] = []
        var fuzzy: [ProjectSkill] = []
        for skill in skills {
            let name = skill.name.lowercased()
            if name.hasPrefix(needle) {
                prefixed.append(skill)
            } else if isSubsequence(needle, of: name) {
                fuzzy.append(skill)
            }
        }
        return prefixed + fuzzy
    }

    /// Whether `needle`'s characters appear in `haystack` in order.
    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var iterator = haystack.makeIterator()
        for character in needle {
            var matched = false
            while let candidate = iterator.next() {
                if candidate == character {
                    matched = true
                    break
                }
            }
            if !matched { return false }
        }
        return true
    }

    // MARK: - Private

    private mutating func reevaluate() {
        let characters = Array(text)

        // A dismissal only outlives the `$` it was aimed at. Delete the `$` and
        // the next one the user types is a fresh invitation.
        if let dismissed = dismissedTokenStart,
           !(characters.indices.contains(dismissed) && characters[dismissed] == Self.trigger) {
            dismissedTokenStart = nil
        }

        guard let start = Self.tokenStart(in: characters, caret: caret),
              start != dismissedTokenStart
        else {
            close()
            return
        }

        let currentQuery = String(characters[(start + 1)..<caret])
        let currentMatches = Self.filter(skills, query: currentQuery)
        guard !currentMatches.isEmpty else {
            // Zero matches closes the HUD but is never recorded as a dismissal:
            // backspacing back into a query that matches re-opens it.
            close()
            return
        }

        tokenStart = start
        query = currentQuery
        matches = currentMatches
        highlightedIndex = 0
        isVisible = true
    }

    private mutating func close() {
        isVisible = false
        matches = []
        query = ""
        tokenStart = nil
        highlightedIndex = 0
    }
}
