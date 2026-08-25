import SwiftUI

struct CleanupReportView: View {
    let envelope: CleanupRunEnvelope
    @Bindable var controller: CleanupRunController
    let preferredPaneIDs: Set<String>?
    @State private var selection = CleanupSelectionPlan()
    @State private var filter = CleanupReportFilter.all
    @State private var isConfirmingClose = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    CleanupReportOverview(envelope: envelope, filter: $filter)
                    if envelope.run.status == .partial {
                        partialRunWarning
                    }
                    ForEach(filteredWorkspaces) { workspace in
                        CleanupWorkspaceDecisionCard(
                            workspace: workspace,
                            panes: workspace.panes.filter(filter.includes),
                            isSelected: selection.contains(workspace),
                            isPaneSelected: selection.contains,
                            toggleWorkspace: { selection.toggleWorkspace(workspace) },
                            togglePane: { selection.togglePane($0, in: workspace) }
                        )
                    }
                    if filteredWorkspaces.isEmpty {
                        ContentUnavailableView(
                            "No panes in this view",
                            systemImage: "line.3.horizontal.decrease.circle",
                            description: Text("Choose another filter to see the rest of the cleanup review.")
                        )
                        .foregroundStyle(HerdrTheme.mist)
                        .padding(.vertical, 30)
                    }
                    judgeFooter
                }
                .padding(20)
            }
            footer
        }
        .onAppear { selection.seed(with: workspaces, preferredPaneIDs: preferredPaneIDs) }
    }

    private var partialRunWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("AI judge unavailable, showing deterministic signals", systemImage: "exclamationmark.triangle.fill")
                .herdrFont(.headline, weight: .bold)
                .foregroundStyle(HerdrTheme.alert)
            if let error = envelope.run.error, !error.isEmpty {
                Text(error)
                    .herdrFont(.subheadline)
                    .foregroundStyle(HerdrTheme.mist)
                    .textSelection(.enabled)
            }
            if let lastError = envelope.run.judge?.lastError, !lastError.isEmpty {
                Text(lastError)
                    .herdrFont(.subheadline)
                    .foregroundStyle(HerdrTheme.mist)
                    .textSelection(.enabled)
            }
            Button("Run again", systemImage: "arrow.clockwise", action: runAgain)
                .accessibilityIdentifier("cleanup-report-retry")
        }
        .padding(14)
        .background(HerdrTheme.alert.opacity(0.12))
        .clipShape(.rect(cornerRadius: 12))
        .accessibilityIdentifier("cleanup-partial-banner")
    }

    private var judgeFooter: some View {
        Group {
            if let config = envelope.run.config, let judge = envelope.run.judge {
                Label(
                    "Judge: \(config.model ?? "server default") · \(config.thinkingLevel.label) · \(judge.costUSD.formatted(.currency(code: "USD"))) · \(duration(milliseconds: judge.durationMs))",
                    systemImage: "sparkles"
                )
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.muted)
                .textSelection(.enabled)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectionSummary)
                    .herdrFont(.caption, weight: .bold)
                    .foregroundStyle(HerdrTheme.text)
                Text(applyPreview)
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.mist)
            }
            Spacer()
            if !selection.isEmpty {
                Button("Clear", action: { selection.clear() })
            }
            Button("Review closures…", systemImage: "checkmark.shield", action: { isConfirmingClose = true })
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("cleanup-close-selected")
                .confirmationDialog(confirmationTitle, isPresented: $isConfirmingClose, titleVisibility: .visible) {
                    Button("End sessions and close", role: .destructive, action: applySelection)
                        .accessibilityIdentifier("cleanup-confirm-close-selected")
                    Button("Cancel", role: .cancel) { }
                        .accessibilityIdentifier("cleanup-confirm-cancel")
                } message: {
                    Text(confirmationMessage)
                }
        }
        .padding(14)
        .background(HerdrTheme.elevated)
    }

    private var workspaces: [CleanupWorkspaceReport] { envelope.workspaces ?? [] }
    private var filteredWorkspaces: [CleanupWorkspaceReport] {
        workspaces.filter { workspace in workspace.panes.contains(where: filter.includes) }
    }
    private var affectedPanes: [CleanupPaneReport] { selection.affectedPanes(in: workspaces) }
    private var affectedWorkspaces: [CleanupWorkspaceReport] { selection.affectedWorkspaces(in: workspaces) }
    private var activePiSessions: Int { selection.activePiSessionCount(in: workspaces) }

    private var selectionSummary: String {
        "\(count(affectedPanes.count, singular: "pane")) across \(count(affectedWorkspaces.count, singular: "workspace")) selected"
    }

    private var applyPreview: String {
        "Ends up to \(count(activePiSessions, singular: "active Pi session")) · saves up to \(count(affectedPanes.count, singular: "ledger link"))"
    }

    private var confirmationTitle: String {
        "Close \(count(affectedPanes.count, singular: "selected pane"))?"
    }

    private var confirmationMessage: String {
        let titles = affectedWorkspaces.map { $0.title ?? $0.label ?? $0.workspaceID }.joined(separator: ", ")
        return "Workspaces: \(titles). Herdr will re-check live safety, record each pane-to-session link, end up to \(count(activePiSessions, singular: "active Pi session")), then close the approved selection. Anything that changed stays open."
    }

    private func applySelection() {
        let paneIDs = selection.normalizedPaneIDs(in: workspaces)
        let workspaceIDs = selection.normalizedWorkspaceIDs()
        Task { await controller.apply(paneIDs: paneIDs, workspaceIDs: workspaceIDs) }
    }

    private func runAgain() {
        Task { await controller.startOver() }
    }

    private func duration(milliseconds: Int) -> String {
        let seconds = milliseconds / 1_000
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    private func count(_ value: Int, singular: String) -> String {
        "\(value) \(value == 1 ? singular : singular + "s")"
    }
}
