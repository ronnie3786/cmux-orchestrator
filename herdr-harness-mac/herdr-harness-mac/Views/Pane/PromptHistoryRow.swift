import AppKit
import SwiftUI

struct PromptHistoryRow: View {
    let entry: PromptHistoryEntry
    let reuse: (String) -> Void
    @State private var isExpanded = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let date = entry.submittedAt {
                    Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.mist)
                }
                Spacer()
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc", action: copy)
                    .accessibilityIdentifier("pane-prompt-history-copy-\(entry.id)")
                Button("Reuse", systemImage: "arrow.uturn.backward") { reuse(entry.text) }
                    .help("Replace this pane's draft with this prompt without sending it")
            }
            .buttonStyle(.borderless)
            .herdrFont(.caption)

            Text(entry.text)
                .herdrFont(.body, monospaced: true)
                .lineLimit(isExpanded ? nil : 4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(isExpanded ? "Show less" : "Show full prompt") { isExpanded.toggle() }
                .buttonStyle(.borderless)
                .herdrFont(.caption)
        }
        .padding(12)
        .background(HerdrTheme.elevated, in: .rect(cornerRadius: HerdrTheme.compactRadius))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setString(entry.text, forType: .string)
    }
}
