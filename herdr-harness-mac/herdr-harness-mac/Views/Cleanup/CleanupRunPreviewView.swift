import SwiftUI

struct CleanupRunPreviewView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What Smart Cleanup checks")
                .herdrFont(.headline, weight: .bold)
                .foregroundStyle(HerdrTheme.text)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Label("Capture", systemImage: "doc.text.magnifyingglass")
                        .foregroundStyle(HerdrTheme.accent)
                    Text("Workspace titles, recent output, alerts, activity, Pi session identity, and known cost")
                }
                GridRow {
                    Label("Summarize", systemImage: "sparkles")
                        .foregroundStyle(HerdrTheme.mauve)
                    Text("A read-only judge explains how each pane was used and why it should stay or close")
                }
                GridRow {
                    Label("Protect", systemImage: "checkmark.shield")
                        .foregroundStyle(HerdrTheme.signal)
                    Text("Hard safety checks override the judge when work is active, focused, starred, changed, unread, or unsafe in Git")
                }
            }
            .herdrFont(.subheadline)
            .foregroundStyle(HerdrTheme.mist)
        }
        .padding(16)
        .background(HerdrTheme.graphite)
        .clipShape(.rect(cornerRadius: 14))
        .accessibilityIdentifier("cleanup-run-preview")
    }
}
