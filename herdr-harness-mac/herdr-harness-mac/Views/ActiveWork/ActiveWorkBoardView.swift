import SwiftUI

struct ActiveWorkBoardView: View {
    @Bindable var store: ActiveWorkStore
    let isControlEnabled: Bool
    let setupJira: (ActiveWorkJiraCandidate) async throws -> Void
    let openURL: (URL) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                summary
                    .padding(.bottom, 6)

                if !store.items.isEmpty {
                    journeySectionHeader

                    ForEach(store.items) { item in
                        ActiveWorkBoardCard(
                            item: item,
                            pipeline: store.pipeline,
                            isSelected: store.selectedItem?.id == item.id,
                            select: { store.select(item.id) },
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
                    .padding(.top, 14)

                    ForEach(store.jiraCandidates) { candidate in
                        ActiveWorkJiraCandidateCard(
                            candidate: candidate,
                            isControlEnabled: isControlEnabled,
                            setup: setupJira,
                            openURL: openURL
                        )
                        .opacity(0.82)
                    }
                }
            }
            .frame(maxWidth: 1120, alignment: .leading)
            .padding(.horizontal, HerdrTheme.pagePadding)
            .padding(.top, 22)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("active-work-board")
    }

    private var summary: some View {
        HStack(spacing: 0) {
            metric(title: "work items", value: store.items.count)
            divider
            metric(title: "agent attachments", value: attachmentCount)
            divider
            metric(title: "need you", value: store.attentionCount, color: HerdrTheme.alert)
        }
        .frame(minHeight: 72)
        .background(HerdrTheme.graphite)
        .clipShape(.rect(cornerRadius: HerdrTheme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                .strokeBorder(HerdrTheme.mist.opacity(0.2), lineWidth: 1)
        }
    }

    private var journeySectionHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Journeys")
                .herdrFont(size: 15, weight: .bold, relativeTo: .headline)
                .foregroundStyle(HerdrTheme.text)

            Spacer(minLength: 8)

            Text("ordered by next intervention")
                .herdrFont(size: 10, monospaced: true, weight: .semibold, relativeTo: .caption)
                .foregroundStyle(HerdrTheme.mist)
                .lineLimit(1)
        }
        .padding(.vertical, 1)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1, height: 34)
    }

    private func metric(
        title: String,
        value: Int,
        color: Color = HerdrTheme.text
    ) -> some View {
        VStack(spacing: 5) {
            Text("\(value)")
                .herdrFont(size: 16, weight: .bold, relativeTo: .headline)
                .monospacedDigit()
                .foregroundStyle(color)
            Text(title)
                .herdrFont(size: 11, relativeTo: .caption)
                .foregroundStyle(HerdrTheme.mist)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(title)")
    }

    private var attachmentCount: Int {
        store.items.reduce(into: 0) { count, item in
            count += ActiveWorkProjection.allAgents(for: item)
                .count(where: { $0.detachedAt == nil })
        }
    }
}

private struct ActiveWorkBoardCard: View {
    let item: ActiveWorkItem
    let pipeline: ActiveWorkPipeline
    let isSelected: Bool
    let select: () -> Void
    let openFocus: () -> Void
    let openURL: (URL) -> Void

    private var status: AgentStatus { ActiveWorkProjection.status(for: item) }

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 0) {
                header

                ActiveWorkPipelineRail(item: item, pipeline: pipeline)
                    .padding(.horizontal, 13)
                    .padding(.top, 11)
                    .padding(.bottom, 10)
                    .background(HerdrTheme.crust.opacity(0.7))
                    .clipShape(.rect(cornerRadius: 14))
                    .padding(.top, 13)

                if isSelected {
                    journeyDetail
                }
            }
            .padding(15)
            .padding(.leading, 5)
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .background {
            ZStack {
                HerdrTheme.graphite.opacity(isSelected ? 1 : 0.78)
                if isSelected {
                    LinearGradient(
                        stops: [
                            .init(color: HerdrTheme.accent.opacity(0.07), location: 0),
                            .init(color: .clear, location: 0.62),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
            }
        }
        .clipShape(.rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(
                    isSelected ? HerdrTheme.accent.opacity(0.5) : HerdrTheme.mist.opacity(0.16),
                    lineWidth: 1
                )
        }
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(item.needsAttention ? HerdrTheme.alert : HerdrTheme.accent)
                .frame(width: 4)
                .padding(.vertical, 17)
                .opacity(0.72)
        }
        .contextMenu {
            Button("Open Focus Route", systemImage: "arrow.right.circle", action: openFocus)
            if let jira = item.jira, let url = jira.browserURL {
                Button("Open \(jira.issueKey) in Jira", systemImage: "arrow.up.right.square") {
                    openURL(url)
                }
            }
        }
        .help(isSelected ? "Journey details shown" : "Reveal journey details")
        .accessibilityHint("Select to reveal this journey's movement, cast, and continuity")
        .accessibilityIdentifier("active-work-card-\(item.id)")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    ActiveWorkJourneyPill(title: formattedKind)
                    ActiveWorkJourneyPill(title: stageSkill)
                }

                Text(displayTitle)
                    .herdrFont(size: 15, weight: .bold, relativeTo: .headline)
                    .foregroundStyle(HerdrTheme.text)
                    .multilineTextAlignment(.leading)
                    .lineLimit(1)
                    .truncationMode(.tail)

                floorAndUpdate
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ActiveWorkAvatarStack(agents: attachedAgents, size: 30, limit: 4)
                .fixedSize()

            ActiveWorkJourneyStatusPill(status: status, item: item, pipeline: pipeline)
                .fixedSize()
        }
    }

    private var floorAndUpdate: some View {
        HStack(spacing: 4) {
            Text("\(floorLabel) · updated")
            if item.updatedAt.flatMap(HerdrTimestamp.date(from:)) != nil {
                ActiveWorkRelativeTimestamp(value: item.updatedAt)
            } else {
                Text("pending")
            }
        }
        .herdrFont(size: 10, monospaced: true, weight: .medium, relativeTo: .caption)
        .foregroundStyle(HerdrTheme.mist)
        .lineLimit(1)
    }

    private var journeyDetail: some View {
        HStack(alignment: .top, spacing: 10) {
            ActiveWorkJourneyDetailBlock(title: "next movement", message: nextMovement)
            ActiveWorkJourneyDetailBlock(title: "traveling cast", message: travelingCast)
            ActiveWorkJourneyDetailBlock(title: "continuity", message: continuity)
        }
        .padding(.horizontal, 5)
        .padding(.top, 12)
        .padding(.bottom, 2)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(HerdrTheme.mist.opacity(0.13))
                .frame(height: 1)
        }
    }

    private var attachedAgents: [ActiveWorkAgent] {
        ActiveWorkProjection.allAgents(for: item).filter { $0.detachedAt == nil }
    }

    private var currentStage: ActiveWorkPipelineStage? {
        pipeline.stages.first(where: { $0.key == item.currentStageKey })
    }

    private var stageSkill: String {
        guard let currentStage else { return "idea intake" }
        return currentStage.skillName ?? currentStage.key
    }

    private var formattedKind: String {
        let normalized = item.kind
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacing("_", with: " ")
        guard let first = normalized.first else { return "Work" }
        return first.uppercased() + normalized.dropFirst()
    }

    private var displayTitle: String {
        guard let key = item.jira?.issueKey.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return item.title }
        return "\(key) · \(item.title)"
    }

    private var floorLabel: String {
        guard let session = allSessions.first(where: { $0.endedAt == nil }) ?? allSessions.first else {
            return "no floor yet"
        }

        let machine = session.machineID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let machineLabel = machine.flatMap { $0.isEmpty ? nil : $0 } ?? "local"
        let workspace = session.workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pane = session.paneID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let route: String?
        if let pane, !pane.isEmpty {
            if pane.contains(":") || workspace == nil || workspace?.isEmpty == true {
                route = pane
            } else if let workspace {
                route = "\(workspace):\(pane)"
            } else {
                route = pane
            }
        } else if let workspace, !workspace.isEmpty {
            route = workspace
        } else {
            route = nil
        }

        return route.map { "\(machineLabel) · \($0)" } ?? machineLabel
    }

    private var nextMovement: String {
        for candidate in [item.nextAction, actionableAttentionReason, item.summary] {
            if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        if let next = ActiveWorkProjection.nextStage(for: item, pipeline: pipeline) {
            return "Move into \(next.title)."
        }
        return "Keep the current route under watch."
    }

    private var travelingCast: String {
        guard !attachedAgents.isEmpty else { return "No agents attached" }
        return attachedAgents.map(\.displayName).joined(separator: " · ")
    }

    private var continuity: String {
        if !item.continuityArtifacts.isEmpty {
            return item.continuityArtifacts.joined(separator: " · ")
        }

        var parts = ["state.json", "handoff.md"]
        if !allSessions.isEmpty {
            parts.append(allSessions.count == 1 ? "session context" : "\(allSessions.count) session contexts")
        }
        if !allThreads.isEmpty {
            parts.append(allThreads.count == 1 ? "thread context" : "\(allThreads.count) thread contexts")
        }
        return parts.joined(separator: " · ")
    }

    private var allSessions: [ActiveWorkPiSession] {
        var seen = Set<String>()
        return (item.piSessions + item.stages.flatMap(\.piSessions)).filter {
            seen.insert($0.id).inserted
        }
    }

    private var allThreads: [ActiveWorkThread] {
        var seen = Set<String>()
        return (item.threads + item.stages.flatMap(\.threads)).filter {
            seen.insert($0.id).inserted
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

private struct ActiveWorkJourneyPill: View {
    let title: String

    var body: some View {
        Text(title)
            .herdrFont(size: 9, monospaced: true, weight: .semibold, relativeTo: .caption)
            .foregroundStyle(HerdrTheme.mist)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(HerdrTheme.elevated.opacity(0.52), in: Capsule())
            .overlay {
                Capsule().strokeBorder(HerdrTheme.mist.opacity(0.2), lineWidth: 1)
            }
    }
}

private struct ActiveWorkJourneyStatusPill: View {
    let status: AgentStatus
    let item: ActiveWorkItem
    let pipeline: ActiveWorkPipeline

    var body: some View {
        HStack(spacing: 5) {
            Text(symbol)
            Text(title)
        }
            .herdrFont(size: 9, monospaced: true, weight: .semibold, relativeTo: .caption)
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(item.needsAttention ? 0.09 : 0.08), in: Capsule())
            .overlay {
                Capsule().strokeBorder(color.opacity(item.needsAttention ? 0.3 : 0.28), lineWidth: 1)
            }
            .accessibilityLabel("Journey status: \(title)")
    }

    private var title: String {
        if item.currentStageKey == nil { return "idea shaping" }
        if item.needsAttention { return "needs you" }
        if let current = pipeline.stages.first(where: { $0.key == item.currentStageKey }),
           current.sequence == pipeline.stages.map(\.sequence).max() {
            return "monitoring"
        }
        return "working"
    }

    private var symbol: String {
        item.needsAttention ? "✋" : "⌁"
    }

    private var color: Color {
        if item.needsAttention { return HerdrTheme.alert }
        if title == "monitoring" { return HerdrTheme.signal }
        return status == .working ? HerdrTheme.working : status.color
    }
}

private struct ActiveWorkJourneyDetailBlock: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .herdrFont(size: 9, monospaced: true, weight: .bold, relativeTo: .caption)
                .foregroundStyle(HerdrTheme.mist)
                .lineLimit(1)
            Text(message)
                .herdrFont(size: 11, relativeTo: .caption)
                .foregroundStyle(HerdrTheme.mist)
                .lineLimit(3)
                .lineSpacing(2)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(HerdrTheme.accent.opacity(0.28))
                .frame(width: 2)
        }
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
                        Button {
                            openURL(url)
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                                .herdrHitTarget(minWidth: 32, minHeight: 32)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(HerdrTheme.mist)
                        .help("Open \(candidate.key) in Jira")
                        .accessibilityLabel("Open \(candidate.key) in Jira")
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
