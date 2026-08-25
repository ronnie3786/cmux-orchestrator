import Foundation

/// Keyboard-selection state for the command palette. Search and navigation are
/// value semantics so wrapping, result replacement, and empty states are all
/// covered without rendering SwiftUI.
struct CommandPaletteState: Equatable, Sendable {
    var query = ""
    private(set) var results: [CommandPaletteEntry]
    private(set) var highlightedIndex = 0
    private var entries: [CommandPaletteEntry]

    init(entries: [CommandPaletteEntry]) {
        self.entries = entries
        results = CommandPaletteIndex.search(entries, query: "")
    }

    var highlightedEntry: CommandPaletteEntry? {
        guard results.indices.contains(highlightedIndex) else { return nil }
        return results[highlightedIndex]
    }

    mutating func queryDidChange() {
        results = CommandPaletteIndex.search(entries, query: query)
        highlightedIndex = 0
    }

    mutating func replaceEntries(_ entries: [CommandPaletteEntry]) {
        let highlightedID = highlightedEntry?.id
        self.entries = entries
        results = CommandPaletteIndex.search(entries, query: query)
        highlightedIndex = highlightedID.flatMap { id in results.firstIndex(where: { $0.id == id }) } ?? 0
    }

    mutating func moveHighlight(by offset: Int) {
        guard !results.isEmpty else { return }
        highlightedIndex = ((highlightedIndex + offset) % results.count + results.count) % results.count
    }

    mutating func highlight(_ index: Int) {
        guard results.indices.contains(index) else { return }
        highlightedIndex = index
    }
}
