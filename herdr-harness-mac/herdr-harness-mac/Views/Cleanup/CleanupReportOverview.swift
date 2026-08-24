import SwiftUI

struct CleanupReportOverview: View {
    let envelope: CleanupRunEnvelope
    @Binding var filter: CleanupReportFilter
    @Environment(\.herdrFontScale) private var fontScale

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cleanup review")
                        .herdrFont(.title2, weight: .bold)
                        .foregroundStyle(HerdrTheme.text)
                    Text(workspaceHeadline)
                        .herdrFont(.subheadline)
                        .foregroundStyle(HerdrTheme.mist)
                        .textSelection(.enabled)
                }
                Spacer()
                Label(judgeStatusTitle, systemImage: judgeStatusSymbol)
                    .herdrFont(.caption, weight: .bold)
                    .foregroundStyle(judgeStatusTone)
            }

            metrics

            Picker("Show panes", selection: $filter) {
                ForEach(CleanupReportFilter.allCases) { option in
                    Text("\(option.label) \(count(for: option))")
                        .tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("cleanup-report-filter")
        }
        .padding(16)
        .background(HerdrTheme.graphite)
        .clipShape(.rect(cornerRadius: 14))
    }

    private var workspaces: [CleanupWorkspaceReport] { envelope.workspaces ?? [] }
    private var panes: [CleanupPaneReport] { workspaces.flatMap(\.panes) }
    private var knownCost: Double { envelope.summary?.totalKnownCostUSD ?? panes.compactMap(\.costUSD).reduce(0, +) }
    private var protectedCount: Int { envelope.summary?.railBlocked ?? panes.count(where: { !$0.blockedBy.isEmpty }) }

    private var judgeStatusTitle: String {
        envelope.run.status == .partial ? "Partial judge result" : "Judge complete"
    }

    private var judgeStatusSymbol: String {
        envelope.run.status == .partial ? "exclamationmark.triangle.fill" : "checkmark.seal.fill"
    }

    private var judgeStatusTone: Color {
        envelope.run.status == .partial ? HerdrTheme.alert : HerdrTheme.signal
    }

    @ViewBuilder
    private var metrics: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            if fontScale >= .xxLarge {
                GridRow {
                    metricReviewed
                    metricReady
                }
                GridRow {
                    metricProtected
                    metricCost
                }
            } else {
                GridRow {
                    metricReviewed
                    metricReady
                    metricProtected
                    metricCost
                }
            }
        }
    }

    private var metricReviewed: some View {
        CleanupMetricTile(title: "panes reviewed", value: "\(panes.count)", symbol: "rectangle.split.3x1", tone: HerdrTheme.accent)
    }

    private var metricReady: some View {
        CleanupMetricTile(title: "ready to close", value: "\(panes.count(where: \.safeToClose))", symbol: "checkmark.circle.fill", tone: HerdrTheme.signal)
    }

    private var metricProtected: some View {
        CleanupMetricTile(title: "safety protected", value: "\(protectedCount)", symbol: "shield.fill", tone: HerdrTheme.working)
    }

    private var metricCost: some View {
        CleanupMetricTile(title: "known Pi spend", value: knownCost.formatted(.currency(code: "USD")), symbol: "dollarsign.circle.fill", tone: HerdrTheme.mauve)
    }

    private var workspaceHeadline: String {
        let titles = envelope.summary?.workspaceTitles ?? workspaces.map { $0.title ?? $0.label ?? $0.workspaceID }
        guard !titles.isEmpty else { return "No workspaces were available to review" }
        let workspaceCount = envelope.summary?.workspacesScanned ?? workspaces.count
        let noun = workspaceCount == 1 ? "workspace" : "workspaces"
        return "Reviewed \(workspaceCount) \(noun): \(titles.joined(separator: ", "))"
    }

    private func count(for option: CleanupReportFilter) -> Int {
        panes.count(where: option.includes)
    }
}
