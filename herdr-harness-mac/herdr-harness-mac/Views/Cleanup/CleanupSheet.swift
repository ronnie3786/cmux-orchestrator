import SwiftUI

struct CleanupSheetTarget: Identifiable {
    let id: String
    let machineID: String
    let machineName: String
    let workspaceID: String?
    let workspaceLabel: String?
}

struct CleanupSheet: View {
    let target: CleanupSheetTarget
    @Bindable var controller: CleanupRunController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        content
            .frame(minWidth: 760, minHeight: 600)
            .background(HerdrTheme.ink)
            .task { controller.resumeIfNeeded() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("cleanup-done")
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .idle:
            idleContent
        case let .running(envelope):
            runningContent(envelope.run, failureMessage: nil)
        case let .report(envelope):
            CleanupReportView(envelope: envelope, controller: controller)
        case let .failure(message):
            runningContent(failedRun(message), failureMessage: message)
        case .applying:
            VStack(spacing: 12) {
                ProgressView()
                Text("Re-checking safety rails and closing your selection…")
                    .herdrFont(.body)
                    .foregroundStyle(HerdrTheme.mist)
            }
        case let .applied(response, _):
            appliedContent(response)
        }
    }

    private var idleContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                titleRow
                Text("Review \(scopeDescription) on \(target.machineName) before anything is closed.")
                    .herdrFont(.body)
                    .foregroundStyle(HerdrTheme.mist)
                configChips
                trustCaption
                Button("Run Smart Cleanup", systemImage: "sparkles") {
                    Task { await controller.start() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("cleanup-run")
            }
            .padding(24)
        }
    }

    private var configChips: some View {
        let settings = CleanupSettings.load(from: .standard)
        return HStack(spacing: 8) {
            configChip("Model", value: settings.model.isEmpty ? "Server default" : settings.model, identifier: "cleanup-config-model")
            configChip("Thinking", value: settings.thinkingLevel.label, identifier: "cleanup-config-thinking")
            configChip("Flag at", value: settings.costThresholdUSD.formatted(.currency(code: "USD")), identifier: "cleanup-config-cost")
        }
    }

    private func configChip(_ title: String, value: String, identifier: String) -> some View {
        Button { openSettings() } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .herdrFont(.caption2)
                    .foregroundStyle(HerdrTheme.muted)
                Text(value)
                    .herdrFont(.caption, monospaced: true, weight: .bold)
                    .lineLimit(1)
            }
            .padding(10)
            .background(HerdrTheme.elevated)
            .clipShape(.rect(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func runningContent(_ run: CleanupRun, failureMessage: String?) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            titleRow
            Text("Reviewing \(scopeDescription) on \(target.machineName)")
                .herdrFont(.body)
                .foregroundStyle(HerdrTheme.mist)
            CleanupTimelineView(
                run: run,
                failureMessage: failureMessage,
                consecutivePollFailures: failureMessage == nil ? controller.consecutivePollFailures : 0,
                lastPollFailureMessage: failureMessage == nil ? controller.lastPollFailureMessage : nil,
                lastPollSucceededAt: failureMessage == nil ? controller.lastPollSucceededAt : nil,
                maxConsecutivePollFailures: CleanupRunController.maxConsecutivePollFailures
            )
            trustCaption
            if failureMessage != nil {
                Button("Retry", systemImage: "arrow.clockwise") {
                    Task { await controller.retry() }
                }
                .accessibilityIdentifier("cleanup-retry")
                if controller.activeRunID != nil {
                    Button("Start over", systemImage: "arrow.counterclockwise") {
                        Task { await controller.startOver() }
                    }
                    .accessibilityIdentifier("cleanup-start-over")
                }
            } else if controller.activeRunID != nil {
                Button("Cancel run", systemImage: "xmark.circle", role: .destructive) {
                    Task { await controller.cancelRun() }
                }
                .accessibilityIdentifier("cleanup-cancel")
            }
            Spacer()
        }
        .padding(24)
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Smart Cleanup")
                .herdrFont(.title2, weight: .bold)
            Text(CleanupFeature.version)
                .herdrFont(.caption2, weight: .semibold)
                .foregroundStyle(HerdrTheme.muted)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(HerdrTheme.elevated)
                .clipShape(.capsule)
        }
    }

    private func appliedContent(_ response: CleanupApplyResponse) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("Cleanup applied", systemImage: "checkmark.circle.fill")
                    .herdrFont(.title2, weight: .bold)
                    .foregroundStyle(HerdrTheme.signal)
                ForEach(response.applied.panes, id: \.self) { id in
                    Label("Closed pane \(id)", systemImage: "checkmark")
                        .herdrFont(.body)
                }
                ForEach(response.applied.workspaces, id: \.self) { id in
                    Label("Closed workspace \(id)", systemImage: "checkmark")
                        .herdrFont(.body)
                }
                ForEach(response.skipped) { item in
                    Label("Skipped \(item.id): \(item.reasonLabel)", systemImage: "exclamationmark.triangle")
                        .herdrFont(.body)
                        .foregroundStyle(HerdrTheme.alert)
                }
            }
            .padding(24)
        }
    }

    private var trustCaption: some View {
        Text("Content is captured to local temp files · the AI judge is read-only · nothing closes without your approval.")
            .herdrFont(.caption)
            .foregroundStyle(HerdrTheme.mist)
            .padding(12)
            .background(HerdrTheme.elevated.opacity(0.7))
            .clipShape(.rect(cornerRadius: 9))
    }

    private var scopeDescription: String { target.workspaceLabel ?? "all workspaces" }

    private func failedRun(_ message: String) -> CleanupRun {
        CleanupRun(runID: "failed", status: .failed, phase: .failed, phaseDetail: nil, progress: nil, phaseHistory: [], error: message)
    }
}
