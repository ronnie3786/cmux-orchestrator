import SwiftUI

struct CleanupApplyingView: View {
    let envelope: CleanupRunEnvelope?

    init(envelope: CleanupRunEnvelope? = nil) {
        self.envelope = envelope
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Applying cleanup safely")
                            .herdrFont(.title2, weight: .bold)
                        Text("Each selected item is checked again before anything closes.")
                            .herdrFont(.body)
                            .foregroundStyle(HerdrTheme.mist)
                    }
                }

                if let envelope {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(envelope.run.phase?.label ?? "Cleanup in progress", systemImage: "bolt.horizontal.circle.fill")
                            .herdrFont(.headline, weight: .bold)
                            .foregroundStyle(HerdrTheme.working)
                        Text(envelope.run.phaseDetail ?? "Waiting for the next server update…")
                            .herdrFont(.body)
                            .foregroundStyle(HerdrTheme.text)
                        if let progress = envelope.run.progress {
                            ProgressView(value: progress.fraction)
                                .tint(HerdrTheme.working)
                                .accessibilityLabel("Cleanup apply progress")
                                .accessibilityValue("\(progress.done) of \(progress.total)")
                            Text("\(progress.done) of \(progress.total) apply steps confirmed")
                                .herdrFont(.caption, monospaced: true)
                                .foregroundStyle(HerdrTheme.mist)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(HerdrTheme.working.opacity(0.09))
                    .clipShape(.rect(cornerRadius: 12))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("cleanup-apply-live-progress")
                }

                if let result = envelope?.applyResult {
                    Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                        GridRow {
                            CleanupMetricTile(
                                title: "Panes closed",
                                value: result.applied.panes.count.formatted(),
                                symbol: "rectangle.fill.on.rectangle.fill",
                                tone: HerdrTheme.signal
                            )
                            CleanupMetricTile(
                                title: "Workspaces closed",
                                value: result.applied.workspaces.count.formatted(),
                                symbol: "rectangle.3.group.fill",
                                tone: HerdrTheme.signal
                            )
                        }
                        GridRow {
                            CleanupMetricTile(
                                title: "Kept open",
                                value: result.skipped.count.formatted(),
                                symbol: "shield.fill",
                                tone: HerdrTheme.alert
                            )
                            CleanupMetricTile(
                                title: "Sessions ended",
                                value: (result.piSessions?.ended ?? 0).formatted(),
                                symbol: "power.circle.fill",
                                tone: HerdrTheme.accent
                            )
                        }
                    }
                    .accessibilityIdentifier("cleanup-apply-live-outcomes")
                }

                VStack(alignment: .leading, spacing: 12) {
                    Label("Re-check live pane, alert, focus, and Git state", systemImage: "arrow.triangle.2.circlepath")
                    Label("Preserve pane-to-Pi-session associations in the cleanup ledger", systemImage: "link.badge.plus")
                    Label("End active Pi sessions before their panes close", systemImage: "power.circle")
                    Label("Close the approved panes and workspaces", systemImage: "rectangle.badge.xmark")
                }
                .herdrFont(.body)
                .foregroundStyle(HerdrTheme.text)
                .padding(16)
                .background(HerdrTheme.graphite)
                .clipShape(.rect(cornerRadius: 14))

                Text("If live state changed or a Pi session cannot end cleanly, that item stays open and appears as skipped.")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.mist)
            }
            .padding(24)
        }
        .accessibilityIdentifier("cleanup-applying")
    }
}
