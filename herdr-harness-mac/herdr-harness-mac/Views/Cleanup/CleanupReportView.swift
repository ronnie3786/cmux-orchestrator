import SwiftUI

struct CleanupReportView: View {
    let envelope: CleanupRunEnvelope
    @Bindable var controller: CleanupRunController
    @State private var selectedPaneIDs: Set<String> = []
    @State private var selectedWorkspaceIDs: Set<String> = []
    @State private var isConfirmingClose = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if envelope.run.status == .partial {
                        partialRunWarning
                    }
                    if let summary = envelope.summary, !summary.costFlags.isEmpty {
                        costFlags(summary)
                    }
                    ForEach(envelope.workspaces ?? []) { workspace in
                        workspaceSection(workspace)
                    }
                    judgeFooter
                }
                .padding(20)
            }
            footer
        }
        .onAppear { seedSelections() }
        .confirmationDialog("Close selected sessions?", isPresented: $isConfirmingClose, titleVisibility: .visible) {
            Button("Close Selected", role: .destructive) {
                Task { await controller.apply(paneIDs: Array(selectedPaneIDs), workspaceIDs: Array(selectedWorkspaceIDs)) }
            }
            .accessibilityIdentifier("cleanup-confirm-close-selected")
            Button("Cancel", role: .cancel) { }
                .accessibilityIdentifier("cleanup-confirm-cancel")
        } message: {
            Text("Herdr will re-check its safety rails before closing anything.")
        }
    }

    private var partialRunWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("AI judge unavailable — showing deterministic signals only", systemImage: "exclamationmark.triangle.fill")
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
            Button("Retry", systemImage: "arrow.clockwise") {
                Task { await controller.retry() }
            }
            .accessibilityIdentifier("cleanup-report-retry")
        }
        .padding(14)
        .background(HerdrTheme.alert.opacity(0.12))
        .clipShape(.rect(cornerRadius: 12))
        .accessibilityIdentifier("cleanup-partial-banner")
    }

    private func costFlags(_ summary: CleanupSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Cost flags", systemImage: "dollarsign.circle.fill")
                .herdrFont(.headline, weight: .bold)
                .foregroundStyle(HerdrTheme.working)
            Text("These sessions have spent more than your \(currency(envelope.run.config?.costThresholdUSD ?? 2.0)) threshold")
                .herdrFont(.subheadline)
                .foregroundStyle(HerdrTheme.mist)
            ForEach(summary.costFlags) { flag in
                Text("\(flag.paneID) · \(currency(flag.costUSD))")
                    .herdrFont(.caption, monospaced: true)
                    .foregroundStyle(HerdrTheme.text)
            }
        }
        .padding(14)
        .background(HerdrTheme.working.opacity(0.12))
        .clipShape(.rect(cornerRadius: 12))
    }

    private func workspaceSection(_ workspace: CleanupWorkspaceReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.3.group")
                    .foregroundStyle(HerdrTheme.accent)
                Text(workspace.label ?? workspace.workspaceID)
                    .herdrFont(.headline, weight: .bold)
                Spacer()
                Text(workspace.git.state.rawValue)
                    .herdrFont(.caption, monospaced: true)
                    .foregroundStyle(HerdrTheme.mist)
                if workspace.workspaceSafeToClose {
                    Toggle("Close workspace", isOn: workspaceSelection(for: workspace))
                        .toggleStyle(.checkbox)
                        .herdrFont(.caption)
                        .accessibilityIdentifier("cleanup-workspace-checkbox-\(workspace.workspaceID)")
                }
            }
            if !workspace.workspaceBlockedBy.isEmpty {
                railChips(workspace.workspaceBlockedBy)
            }
            ForEach(workspace.panes) { pane in
                paneRow(pane)
            }
        }
        .padding(14)
        .background(HerdrTheme.graphite)
        .clipShape(.rect(cornerRadius: 12))
    }

    private func paneRow(_ pane: CleanupPaneReport) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: paneSelection(for: pane))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(!pane.safeToClose)
                .accessibilityIdentifier("cleanup-pane-checkbox-\(pane.paneID)")
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    classificationChip(pane.classification)
                    Text(pane.title ?? pane.paneID)
                        .herdrFont(.subheadline, weight: .bold)
                        .lineLimit(1)
                    Text("\(Int((pane.confidence * 100).rounded()))%")
                        .herdrFont(.caption, monospaced: true)
                        .foregroundStyle(HerdrTheme.mist)
                    if let cost = pane.costUSD {
                        Text(currency(cost))
                            .herdrFont(.caption, monospaced: true, weight: .bold)
                            .foregroundStyle(pane.costOverThreshold ? HerdrTheme.working : HerdrTheme.mist)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background((pane.costOverThreshold ? HerdrTheme.working : HerdrTheme.elevated).opacity(0.16))
                            .clipShape(.capsule)
                    }
                }
                Text(pane.reason)
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.mist)
                    .lineLimit(2)
                if !pane.blockedBy.isEmpty {
                    railChips(pane.blockedBy)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .opacity(pane.safeToClose ? 1 : 0.7)
    }

    private func classificationChip(_ classification: CleanupClassification) -> some View {
        Label(classification.label, systemImage: classification.symbol)
            .herdrFont(.caption, weight: .bold)
            .foregroundStyle(classification.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(classification.color.opacity(0.14))
            .clipShape(.capsule)
            .help(classification.tooltip)
    }

    private func railChips(_ codes: [String]) -> some View {
        FlowLayout(spacing: 5) {
            ForEach(codes, id: \.self) { code in
                Text(CleanupRail.label(for: code))
                    .herdrFont(.caption2)
                    .foregroundStyle(HerdrTheme.alert)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(HerdrTheme.alert.opacity(0.13))
                    .clipShape(.capsule)
            }
        }
    }

    private var judgeFooter: some View {
        Group {
            if let config = envelope.run.config, let judge = envelope.run.judge {
                Text("Judge: \(config.model ?? "server default") · \(config.thinkingLevel.label) · \(currency(judge.costUSD)) · \(duration(milliseconds: judge.durationMs))")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.muted)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("\(selectedPaneIDs.count) panes · \(selectedWorkspaceIDs.count) workspaces selected · frees ~\(estimatedFreedPanes) panes")
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.mist)
            Spacer()
            Button("Close Selected", systemImage: "trash", role: .destructive) {
                isConfirmingClose = true
            }
            .disabled(selectedPaneIDs.isEmpty && selectedWorkspaceIDs.isEmpty)
            .accessibilityIdentifier("cleanup-close-selected")
        }
        .padding(14)
        .background(HerdrTheme.elevated)
    }

    private func paneSelection(for pane: CleanupPaneReport) -> Binding<Bool> {
        Binding(
            get: { selectedPaneIDs.contains(pane.paneID) },
            set: { isSelected in
                if isSelected { selectedPaneIDs.insert(pane.paneID) } else { selectedPaneIDs.remove(pane.paneID) }
            }
        )
    }

    private func workspaceSelection(for workspace: CleanupWorkspaceReport) -> Binding<Bool> {
        Binding(
            get: { selectedWorkspaceIDs.contains(workspace.workspaceID) },
            set: { isSelected in
                if isSelected { selectedWorkspaceIDs.insert(workspace.workspaceID) } else { selectedWorkspaceIDs.remove(workspace.workspaceID) }
            }
        )
    }

    private func seedSelections() {
        guard selectedPaneIDs.isEmpty, selectedWorkspaceIDs.isEmpty else { return }
        selectedPaneIDs = Set((envelope.workspaces ?? []).flatMap { workspace in
            workspace.panes.filter(\.safeToClose).map(\.paneID)
        })
    }

    private var estimatedFreedPanes: Int {
        let workspacePanes = (envelope.workspaces ?? [])
            .filter { selectedWorkspaceIDs.contains($0.workspaceID) }
            .flatMap(\.panes)
            .map(\.paneID)
        return Set(workspacePanes).union(selectedPaneIDs).count
    }

    private func currency(_ value: Double) -> String { value.formatted(.currency(code: "USD")) }

    private func duration(milliseconds: Int) -> String {
        let seconds = milliseconds / 1_000
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
