import AppKit
import SwiftUI

struct PromptHistoryView: View {
    let entries: [PromptHistoryEntry]
    let reuse: (String) -> Void
    @State private var query = ""

    private var matchingEntries: [PromptHistoryEntry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.reversed().filter { term.isEmpty || $0.text.localizedStandardContains(term) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Prompt history")
                    .herdrFont(.headline, weight: .bold)
                Spacer()
                Text("\(entries.count) submitted")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.mist)
            }
            TextField("Search prompts", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("pane-prompt-history-search")

            if entries.isEmpty {
                ContentUnavailableView(
                    "No prompts yet", systemImage: "text.bubble",
                    description: Text("Prompts you submit in this pane will be saved here.")
                )
            } else if matchingEntries.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(matchingEntries) { entry in
                            PromptHistoryRow(entry: entry, reuse: reuse)
                        }
                    }
                }
                .scrollIndicators(.visible)
            }
        }
        .padding(HerdrTheme.cardPadding)
        .frame(width: 500, height: 480)
        .foregroundStyle(HerdrTheme.text)
        .background(HerdrTheme.graphite)
        .accessibilityIdentifier("pane-prompt-history-content")
    }
}
