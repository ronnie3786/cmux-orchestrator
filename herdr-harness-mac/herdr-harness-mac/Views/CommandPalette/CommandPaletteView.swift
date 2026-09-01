import SwiftUI

/// Spotlight-style, keyboard-first navigation across every pane in the fleet.
/// The overlay owns only transient query and highlight state; opening a result
/// is handed back to the shell so every route uses the same pane intent.
struct CommandPaletteView: View {
    let entries: [CommandPaletteEntry]
    let focusRequest: Int
    let dismiss: () -> Void
    let select: (CommandPaletteEntry) -> Void

    @State private var state: CommandPaletteState
    @FocusState private var isSearchFocused: Bool

    init(
        entries: [CommandPaletteEntry],
        focusRequest: Int,
        dismiss: @escaping () -> Void,
        select: @escaping (CommandPaletteEntry) -> Void
    ) {
        self.entries = entries
        self.focusRequest = focusRequest
        self.dismiss = dismiss
        self.select = select
        _state = State(initialValue: CommandPaletteState(entries: entries))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Button(action: dismiss) {
                Color.clear
            }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(HerdrTheme.ink.opacity(0.74))
                .contentShape(.rect)
                .focusEffectDisabled()
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Label("Open chat", systemImage: "sparkle.magnifyingglass")
                        .herdrFont(.headline, monospaced: true, weight: .bold)
                        .foregroundStyle(HerdrTheme.text)

                    Spacer(minLength: 12)

                    Text("⌘K")
                        .herdrFont(.caption, monospaced: true, weight: .bold)
                        .foregroundStyle(HerdrTheme.mist)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(HerdrTheme.elevated, in: .rect(cornerRadius: 6))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .herdrFont(.body, weight: .bold)
                        .foregroundStyle(isSearchFocused ? HerdrTheme.accent : HerdrTheme.mist)
                        .accessibilityHidden(true)

                    TextField("Search by chat, agent, workspace, tab, or machine", text: $state.query)
                        .textFieldStyle(.plain)
                        .herdrFont(.body, monospaced: true)
                        .foregroundStyle(HerdrTheme.text)
                        .autocorrectionDisabled()
                        .focused($isSearchFocused)
                        .onKeyPress(.downArrow, phases: .down) { _ in
                            state.moveHighlight(by: 1)
                            return .handled
                        }
                        .onKeyPress(.upArrow, phases: .down) { _ in
                            state.moveHighlight(by: -1)
                            return .handled
                        }
                        .onKeyPress(.return, phases: .down) { _ in
                            openHighlightedEntry()
                            return .handled
                        }
                        .onKeyPress(.escape, phases: .down) { _ in
                            dismiss()
                            return .handled
                        }
                        .accessibilityLabel("Search chats")
                        .accessibilityValue(resultSummary)
                        .accessibilityIdentifier("command-palette-search")

                    if !state.query.isEmpty {
                        Button(action: clearQuery) {
                            Image(systemName: "xmark.circle.fill")
                                .herdrHitTarget(minWidth: 32, minHeight: 32)
                        }
                            .buttonStyle(.plain)
                            .foregroundStyle(HerdrTheme.mist)
                            .help("Clear search")
                            .accessibilityLabel("Clear search")
                            .accessibilityIdentifier("command-palette-clear")
                    }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 50)
                .background(HerdrTheme.elevated)
                .overlay {
                    RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                        .strokeBorder(isSearchFocused ? HerdrTheme.accent : HerdrTheme.surface, lineWidth: 1)
                }
                .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
                .padding(.horizontal, 14)
                .padding(.bottom, 12)

                Rectangle()
                    .fill(HerdrTheme.surface)
                    .frame(height: 1)
                    .accessibilityHidden(true)

                ScrollViewReader { proxy in
                    Group {
                        if state.results.isEmpty {
                            ContentUnavailableView(
                                "No chats found",
                                systemImage: "magnifyingglass",
                                description: Text("Try a title, agent, workspace, tab, or machine name.")
                            )
                            .foregroundStyle(HerdrTheme.mist)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityIdentifier("command-palette-empty")
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(Array(state.results.enumerated()), id: \.element.id) { index, entry in
                                        CommandPaletteRow(
                                            entry: entry,
                                            isHighlighted: index == state.highlightedIndex,
                                            action: { open(entry) },
                                            highlight: { state.highlight(index) }
                                        )
                                        .id(entry.id)
                                    }
                                }
                            }
                            .scrollIndicators(.hidden)
                        }
                    }
                    .frame(height: resultsHeight)
                    .onChange(of: state.highlightedEntry?.id) { _, entryID in
                        if let entryID {
                            proxy.scrollTo(entryID, anchor: .center)
                        }
                    }
                }

                Rectangle()
                    .fill(HerdrTheme.surface)
                    .frame(height: 1)
                    .accessibilityHidden(true)

                HStack(spacing: 12) {
                    Text(resultSummary)
                    Spacer(minLength: 12)
                    Text("↑↓ move   ↩ open   esc close")
                }
                .herdrFont(.caption, monospaced: true)
                .foregroundStyle(HerdrTheme.mist)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .accessibilityHidden(true)
            }
            .frame(width: 640)
            .background(HerdrTheme.graphite, in: .rect(cornerRadius: HerdrTheme.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                    .strokeBorder(HerdrTheme.surface, lineWidth: 1)
            }
            .shadow(color: HerdrTheme.ink.opacity(0.7), radius: 28, y: 12)
            .padding(.top, 72)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Open chat command palette")
            .accessibilityIdentifier("command-palette")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: state.query) {
            state.queryDidChange()
        }
        .onChange(of: entries) { _, newEntries in
            state.replaceEntries(newEntries)
        }
        .task(id: focusRequest) {
            await Task.yield()
            isSearchFocused = true
        }
        .onExitCommand(perform: dismiss)
    }

    private var resultSummary: String {
        let count = state.results.count
        return "\(count) \(count == 1 ? "chat" : "chats")"
    }

    private var resultsHeight: Double {
        guard !state.results.isEmpty else { return 150 }
        return min(max(Double(state.results.count) * 58, 58), 406)
    }

    private func clearQuery() {
        state.query = ""
        isSearchFocused = true
    }

    private func openHighlightedEntry() {
        guard let entry = state.highlightedEntry else { return }
        open(entry)
    }

    private func open(_ entry: CommandPaletteEntry) {
        select(entry)
    }
}
