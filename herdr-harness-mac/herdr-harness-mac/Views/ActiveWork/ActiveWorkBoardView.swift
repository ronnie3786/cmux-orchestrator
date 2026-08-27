import SwiftUI

struct ActiveWorkBoardView: View {
    @Bindable var store: ActiveWorkStore
    let isControlEnabled: Bool
    let setupJira: (ActiveWorkJiraCandidate) async throws -> Void
    let openURL: (URL) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                summary

                if !store.items.isEmpty {
                    HerdrSectionLabel(
                        title: "PIPELINE",
                        detail: "\(store.items.count) item\(store.items.count == 1 ? "" : "s")"
                    )
                    ForEach(store.items) { item in
                        ActiveWorkBoardCard(
                            item: item,
                            pipeline: store.pipeline,
                            openFocus: { store.select(item.id, revealFocus: true) },
                            openURL: openURL
                        )
                    }
                }

                if !store.jiraCandidates.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HerdrSectionLabel(
                            title: "JIRA CANDIDATES",
                            detail: "\(store.jiraCandidates.count) untracked"
                        )
                        Text("Set up creates the board record. Buzz channel and driver setup follow in Buzz Desktop.")
                            .herdrFont(.caption)
                            .foregroundStyle(HerdrTheme.muted)
                    }

                    ForEach(store.jiraCandidates) { candidate in
                        ActiveWorkJiraCandidateCard(
                            candidate: candidate,
                            isControlEnabled: isControlEnabled,
                            setup: setupJira,
                            openURL: openURL
                        )
                    }
                }
            }
            .frame(maxWidth: 1160, alignment: .leading)
            .padding(.horizontal, HerdrTheme.pagePadding)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("active-work-board")
    }

    private var summary: some View {
        GlassCard {
            HStack(spacing: 0) {
                metric(title: "active", value: store.activeItemCount, symbol: "rectangle.3.group", color: HerdrTheme.accent)
                divider
                metric(title: "agents", value: store.activeAgentCount, symbol: "person.2.fill", color: HerdrTheme.mauve)
                divider
                metric(title: "need you", value: store.attentionCount, symbol: "hand.raised.fill", color: HerdrTheme.alert)
                divider
                metric(title: "set up", value: store.jiraCandidates.count, symbol: "plus.square.on.square", color: HerdrTheme.working)
            }
            .padding(.vertical, 12)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(HerdrTheme.surface.opacity(0.7))
            .frame(width: 1, height: 44)
    }

    private func metric(title: String, value: Int, symbol: String, color: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value)")
                    .herdrFont(.headline, monospaced: true, weight: .bold, monospacedDigit: true)
                    .foregroundStyle(HerdrTheme.text)
                Text(title)
                    .herdrFont(.caption, monospaced: true)
                    .foregroundStyle(HerdrTheme.mist)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(title)")
    }
}

private struct ActiveWorkBoardCard: View {
    let item: ActiveWorkItem
    let pipeline: ActiveWorkPipeline
    let openFocus: () -> Void
    let openURL: (URL) -> Void

    private var status: AgentStatus { ActiveWorkProjection.status(for: item) }

    var body: some View {
        GlassCard {
            HStack(alignment: .top, spacing: 0) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(status.color)
                    .frame(width: 4)
                    .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 13) {
                    header

                    if !item.summary.isEmpty {
                        Text(item.summary)
                            .herdrFont(.subheadline)
                            .foregroundStyle(HerdrTheme.mist)
                            .lineLimit(2)
                    }

                    ActiveWorkPipelineRail(item: item, pipeline: pipeline)
                        .padding(12)
                        .background(HerdrTheme.ink.opacity(0.62))
                        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))

                    if let reason = actionableAttentionReason {
                        Label(reason, systemImage: "hand.raised.fill")
                            .herdrFont(.subheadline, weight: .semibold)
                            .foregroundStyle(HerdrTheme.alert)
                            .lineLimit(2)
                            .accessibilityLabel("Needs your attention: \(reason)")
                    }

                    if let nextAction = item.nextAction, !nextAction.isEmpty {
                        Label(nextAction, systemImage: "arrow.forward.circle.fill")
                            .herdrFont(.subheadline, weight: .medium)
                            .foregroundStyle(item.needsAttention ? HerdrTheme.alert : HerdrTheme.text)
                            .lineLimit(2)
                    }

                    footer
                }
                .padding(HerdrTheme.cardPadding)
            }
        }
        .accessibilityIdentifier("active-work-card-\(item.id)")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    if let jira = item.jira, !jira.issueKey.isEmpty {
                        Text(jira.issueKey)
                            .herdrFont(.caption, monospaced: true, weight: .bold)
                            .foregroundStyle(HerdrTheme.mauve)
                    }
                    Text(item.kind.uppercased())
                        .herdrFont(.caption2, monospaced: true, weight: .bold)
                        .foregroundStyle(HerdrTheme.muted)
                }

                Button(action: openFocus) {
                    HStack(spacing: 7) {
                        Text(item.title)
                            .herdrFont(.title3, weight: .bold)
                            .fontDesign(.rounded)
                            .foregroundStyle(HerdrTheme.text)
                            .multilineTextAlignment(.leading)
                        Image(systemName: "chevron.right")
                            .herdrFont(.caption, weight: .bold)
                            .foregroundStyle(HerdrTheme.muted)
                    }
                }
                .buttonStyle(.plain)
                .help("Open Focus Route")
                .accessibilityLabel("Open Focus Route for \(item.title)")
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 7) {
                AgentStatusBadge(status: status, compact: true)
                ActiveWorkReadinessBadge(readiness: item.readiness)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            ActiveWorkMetadataChip(title: "rev \(item.revision)", symbol: "arrow.triangle.2.circlepath")
            if let current = pipeline.stages.first(where: { $0.key == item.currentStageKey }) {
                ActiveWorkMetadataChip(title: current.shortTitle.lowercased(), symbol: "point.topleft.down.to.point.bottomright.curvepath")
            }
            if let jira = item.jira, !jira.status.isEmpty {
                ActiveWorkMetadataChip(
                    title: jira.status.lowercased(),
                    symbol: "checkmark.square",
                    color: HerdrTheme.mauve
                )
                .accessibilityLabel("Jira status: \(jira.status)")
            }
            if let updatedAt = item.updatedAt {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                    ActiveWorkRelativeTimestamp(value: updatedAt)
                }
                .herdrFont(.caption, monospaced: true)
                .foregroundStyle(HerdrTheme.muted)
            }

            Spacer(minLength: 8)

            if let jira = item.jira, let url = jira.browserURL {
                Button {
                    openURL(url)
                } label: {
                    Label(jira.issueKey, systemImage: "arrow.up.right.square")
                        .herdrFont(.caption, monospaced: true, weight: .bold)
                }
                .buttonStyle(.plain)
                .foregroundStyle(HerdrTheme.accent)
                .help("Open in Jira")
            }
        }
    }

    private var actionableAttentionReason: String? {
        guard item.needsAttention,
              let reason = item.attentionReason?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty else { return nil }
        let nextAction = item.nextAction?.trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.caseInsensitiveCompare(nextAction ?? "") == .orderedSame ? nil : reason
    }
}

private struct ActiveWorkJiraCandidateCard: View {
    let candidate: ActiveWorkJiraCandidate
    let isControlEnabled: Bool
    let setup: (ActiveWorkJiraCandidate) async throws -> Void
    let openURL: (URL) -> Void

    @State private var isSettingUp = false
    @State private var didCreate = false
    @State private var errorMessage: String?

    private var isOnBoard: Bool {
        didCreate || candidate.workItemID != nil || candidate.setupState == .onBoard
    }

    var body: some View {
        GlassCard(radius: HerdrTheme.compactRadius) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 13) {
                    Image(systemName: "checkmark.square")
                        .herdrFont(.headline)
                        .foregroundStyle(HerdrTheme.accent)
                        .frame(width: 34, height: 34)
                        .background(HerdrTheme.accent.opacity(0.1), in: Circle())

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 7) {
                            Text(candidate.key)
                                .herdrFont(.caption, monospaced: true, weight: .bold)
                                .foregroundStyle(HerdrTheme.mauve)
                            Text(candidate.status)
                                .herdrFont(.caption2, monospaced: true)
                                .foregroundStyle(HerdrTheme.mist)
                        }
                        Text(candidate.title)
                            .herdrFont(.headline, weight: .bold)
                            .foregroundStyle(HerdrTheme.text)
                        Text(isOnBoard
                             ? "Board record created. Buzz setup is next."
                             : "Create its board record with one click. Buzz setup follows.")
                            .herdrFont(.caption)
                            .foregroundStyle(isOnBoard ? HerdrTheme.mauve : HerdrTheme.muted)
                    }

                    Spacer(minLength: 10)

                    if let url = candidate.browserURL {
                        Button("Open \(candidate.key) in Jira", systemImage: "arrow.up.right.square") {
                            openURL(url)
                        }
                        .labelStyle(.iconOnly)
                        .frame(width: 32, height: 32)
                        .buttonStyle(.plain)
                        .foregroundStyle(HerdrTheme.mist)
                        .help("Open \(candidate.key) in Jira")
                    }

                    setupButton
                }

                if let errorMessage {
                    Text(errorMessage)
                        .herdrFont(.caption, monospaced: true)
                        .foregroundStyle(HerdrTheme.alert)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
        }
    }

    private var setupButton: some View {
        Button {
            Task { await runSetup() }
        } label: {
            Group {
                if isSettingUp {
                    ProgressView().controlSize(.small)
                } else {
                    Label(isOnBoard ? "On board" : "Set up", systemImage: isOnBoard ? "checkmark" : "plus")
                }
            }
            .frame(minWidth: 72, minHeight: 30)
        }
        .buttonStyle(.borderedProminent)
        .tint(isOnBoard ? HerdrTheme.signal : HerdrTheme.accent)
        .disabled(isSettingUp || isOnBoard || candidate.setupState == .unavailable || !isControlEnabled)
        .help(
            !isControlEnabled
                ? "Control access is required to set up Jira work"
                : isOnBoard ? "This Jira item has a board record" : "Create an Active Work board record"
        )
        .accessibilityIdentifier("active-work-jira-setup-\(candidate.key)")
    }

    @MainActor
    private func runSetup() async {
        guard !isSettingUp, !isOnBoard else { return }
        isSettingUp = true
        errorMessage = nil
        defer { isSettingUp = false }
        do {
            try await setup(candidate)
            didCreate = true
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
