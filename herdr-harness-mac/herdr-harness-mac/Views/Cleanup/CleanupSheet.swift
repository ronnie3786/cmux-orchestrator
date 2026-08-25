import SwiftUI

struct CleanupSheetTarget: Identifiable {
    let id: String
    let machineID: String
    let machineName: String
    let workspaceID: String?
    let workspaceLabel: String?
    let workspaceIDs: [String]
    let preferredPaneIDs: Set<String>?

    init(
        id: String,
        machineID: String,
        machineName: String,
        workspaceID: String?,
        workspaceLabel: String?,
        workspaceIDs: [String] = [],
        preferredPaneIDs: Set<String>? = nil
    ) {
        self.id = id
        self.machineID = machineID
        self.machineName = machineName
        self.workspaceID = workspaceID
        self.workspaceLabel = workspaceLabel
        self.workspaceIDs = workspaceIDs
        self.preferredPaneIDs = preferredPaneIDs
    }

    var requestedWorkspaceIDs: [String] {
        workspaceIDs.isEmpty ? workspaceID.map { [$0] } ?? [] : workspaceIDs
    }
}

struct CleanupSheet: View {
    let target: CleanupSheetTarget
    @Bindable var controller: CleanupRunController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @State private var isShowingProcessInfo = false

    var body: some View {
        content
            .frame(minWidth: 760, minHeight: 600)
            .background(HerdrTheme.ink)
            .task { controller.resumeIfNeeded() }
            .interactiveDismissDisabled(isBusy)
            .toolbar {
                ToolbarItem(placement: .secondaryAction) {
                    if isReportVisible {
                        Button("How cleanup works", systemImage: "info.circle") {
                            isShowingProcessInfo = true
                        }
                        .accessibilityIdentifier("cleanup-process-info")
                        .popover(isPresented: $isShowingProcessInfo) {
                            ScrollView {
                                CleanupRunPreviewView()
                                    .padding(20)
                            }
                            .frame(width: 440, height: 360)
                            .background(HerdrTheme.ink)
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Done") { dismiss() }
                        .disabled(isBusy)
                        .help(doneHelp)
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
            CleanupReportView(
                envelope: envelope,
                controller: controller,
                preferredPaneIDs: target.preferredPaneIDs
            )
        case let .failure(message):
            runningContent(failedRun(message), failureMessage: message)
        case let .applying(envelope):
            CleanupApplyingView(envelope: envelope)
        case let .applyStatusUnknown(message):
            applyStatusUnknownContent(message)
        case let .applied(response, envelope):
            CleanupAppliedView(response: response, envelope: envelope)
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
                CleanupRunPreviewView()
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

    private func applyStatusUnknownContent(_ message: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                titleRow
                Label("Cleanup status needs confirmation", systemImage: "wifi.exclamationmark")
                    .herdrFont(.title2, weight: .bold)
                    .foregroundStyle(HerdrTheme.alert)
                Text("Herdr lost reliable contact while applying your selections. The server may still be ending Pi sessions or closing panes, so this window stays locked until status is confirmed.")
                    .herdrFont(.body)
                    .foregroundStyle(HerdrTheme.text)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Last connection error")
                        .herdrFont(.headline, weight: .bold)
                    Text(message)
                        .herdrFont(.body)
                        .foregroundStyle(HerdrTheme.mist)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(HerdrTheme.alert.opacity(0.09))
                .clipShape(.rect(cornerRadius: 12))

                if let envelope = controller.latestApplyEnvelope {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Last confirmed server update")
                            .herdrFont(.headline, weight: .bold)
                        Text(envelope.run.phaseDetail ?? envelope.run.phase?.label ?? "Cleanup was still in progress.")
                            .herdrFont(.body)
                            .foregroundStyle(HerdrTheme.text)
                        if let progress = envelope.run.progress {
                            Text("\(progress.done) of \(progress.total) apply steps confirmed")
                                .herdrFont(.caption, monospaced: true)
                                .foregroundStyle(HerdrTheme.mist)
                        }
                        if let result = envelope.applyResult {
                            Text("\(result.applied.panes.count) panes and \(result.applied.workspaces.count) workspaces closed · \(result.skipped.count) kept open · \(result.piSessions?.ended ?? 0) sessions ended")
                                .herdrFont(.caption, monospaced: true)
                                .foregroundStyle(HerdrTheme.mist)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(HerdrTheme.graphite)
                    .clipShape(.rect(cornerRadius: 12))
                }

                Button("Retry Status", systemImage: "arrow.clockwise") {
                    Task { await controller.retryApplyStatus() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("cleanup-retry-apply-status")

                Text("Retry Status safely reuses the same run and selections. It will not create duplicate cleanup work.")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.mist)
            }
            .padding(24)
        }
        .accessibilityIdentifier("cleanup-apply-status-unknown")
    }

    private var trustCaption: some View {
        Text("Evidence is stored locally; processing follows your configured Pi model and provider · the AI judge is read-only · active Pi sessions end before panes close · closure links are saved locally.")
            .herdrFont(.caption)
            .foregroundStyle(HerdrTheme.mist)
            .padding(12)
            .background(HerdrTheme.elevated.opacity(0.7))
            .clipShape(.rect(cornerRadius: 9))
    }

    private var scopeDescription: String { target.workspaceLabel ?? "all workspaces" }

    private var isBusy: Bool {
        switch controller.state {
        case .running, .applying, .applyStatusUnknown:
            true
        case .idle, .report, .failure, .applied:
            false
        }
    }

    private var doneHelp: String {
        switch controller.state {
        case .applyStatusUnknown:
            "Retry cleanup status before closing Smart Cleanup"
        case .running, .applying:
            "Wait for the cleanup operation to finish or cancel it first"
        case .idle, .report, .failure, .applied:
            "Close Smart Cleanup"
        }
    }

    private var isReportVisible: Bool {
        if case .report = controller.state { return true }
        return false
    }

    private func failedRun(_ message: String) -> CleanupRun {
        CleanupRun(runID: "failed", status: .failed, phase: .failed, phaseDetail: nil, progress: nil, phaseHistory: [], error: message)
    }
}
