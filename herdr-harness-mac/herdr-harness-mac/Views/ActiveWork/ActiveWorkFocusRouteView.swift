import SwiftUI

struct ActiveWorkFocusRouteView: View {
    @Bindable var store: ActiveWorkStore
    let isControlEnabled: Bool
    let openSession: (ActiveWorkPiSession) -> Void
    let openURL: (URL) -> Void
    let transition: (ActiveWorkItem, ActiveWorkPipelineStage) async throws -> Void
    let setLifecycle: (ActiveWorkItem, String) async throws -> Void

    @State private var isRouteBriefExpanded = false
    @State private var isRouteDetailsExpanded = true

    var body: some View {
        Group {
            if store.items.isEmpty {
                ContentUnavailableView(
                    "No routes yet",
                    systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                    description: Text("Set up a Jira candidate or create new work to begin a Focus Route.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    if geometry.size.width >= 820 {
                        HStack(alignment: .top, spacing: 14) {
                            itemList
                                .frame(width: 255)
                            detail(horizontalPadding: 0)
                        }
                        .padding(.horizontal, HerdrTheme.pagePadding)
                        .padding(.vertical, 18)
                        .frame(maxWidth: 1_156, maxHeight: .infinity, alignment: .top)
                        .frame(maxWidth: .infinity)
                    } else {
                        VStack(spacing: 0) {
                            compactItemPicker
                            Rectangle()
                                .fill(HerdrTheme.surface.opacity(0.72))
                                .frame(height: 1)
                            detail(horizontalPadding: HerdrTheme.pagePadding)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("active-work-focus-route")
    }

    private var itemList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(store.items) { item in
                    focusItemButton(item, compact: false)
                }
            }
            .padding(.bottom, 18)
        }
        .scrollIndicators(.hidden)
    }

    private var compactItemPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(store.items) { item in
                    focusItemButton(item, compact: true)
                        .frame(width: 230)
                }
            }
            .padding(.horizontal, HerdrTheme.pagePadding)
            .padding(.vertical, 10)
        }
        .background(HerdrTheme.graphite.opacity(0.52))
        .scrollIndicators(.hidden)
    }

    private func focusItemButton(_ item: ActiveWorkItem, compact: Bool) -> some View {
        let isSelected = store.selectedItem?.id == item.id
        let status = ActiveWorkProjection.status(for: item)
        let agents = ActiveWorkProjection.allAgents(for: item)

        return Button {
            store.select(item.id)
        } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(focusTitle(for: item))
                        .herdrFont(size: 11, weight: .bold, relativeTo: .caption)
                        .foregroundStyle(HerdrTheme.text)
                        .lineLimit(compact ? 1 : 2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(status.color)
                            .frame(width: 5, height: 5)
                        Text(status.title.lowercased())
                    }
                    .herdrFont(size: 9, monospaced: true, weight: .medium, relativeTo: .caption)
                    .foregroundStyle(isSelected ? HerdrTheme.mist : HerdrTheme.muted)
                    .lineLimit(1)
                }

                Spacer(minLength: 3)
                if !agents.isEmpty {
                    ActiveWorkAvatarStack(agents: agents, size: 24, limit: 2)
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 59, alignment: .leading)
            .background {
                ZStack {
                    HerdrTheme.graphite
                    if isSelected {
                        LinearGradient(
                            colors: [HerdrTheme.accent.opacity(0.11), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    }
                }
            }
            .clipShape(.rect(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(isSelected ? HerdrTheme.accent.opacity(0.52) : .clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title), \(status.title)")
        .accessibilityHint("Shows this work item's route")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("active-work-focus-item-\(item.id)")
    }

    @ViewBuilder
    private func detail(horizontalPadding: CGFloat) -> some View {
        if let item = store.selectedItem {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ActiveWorkFocusHero(
                        item: item,
                        pipeline: store.pipeline,
                        stages: store.stages
                    )

                    let currentStage = store.pipeline.stages.first { $0.key == item.currentStageKey }
                    if item.lifecycle.lowercased() == "done" {
                        ActiveWorkLifecycleCard(
                            item: item,
                            action: .archive,
                            isControlEnabled: isControlEnabled,
                            setLifecycle: setLifecycle
                        )
                            .id("\(item.id)-archive-\(item.revision)")
                    } else if let nextStage = ActiveWorkProjection.nextStage(for: item, pipeline: store.pipeline) {
                        ActiveWorkTransitionCard(
                            item: item,
                            currentStage: currentStage,
                            nextStage: nextStage,
                            isControlEnabled: isControlEnabled,
                            transition: transition
                        )
                        .id("\(item.id)-\(nextStage.key)")
                    } else if currentStage?.key == "pr-triage" {
                        ActiveWorkLifecycleCard(
                            item: item,
                            action: .complete,
                            isControlEnabled: isControlEnabled,
                            setLifecycle: setLifecycle
                        )
                            .id("\(item.id)-complete-\(item.revision)")
                    }

                    routeBrief(item)

                    let unscopedThreads = item.threads.filter { $0.stageID == nil && $0.stageKey == nil }
                    routeDetails(item, unscopedThreads: unscopedThreads)
                }
                .frame(maxWidth: 900, alignment: .leading)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, horizontalPadding == 0 ? 0 : 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func routeBrief(_ item: ActiveWorkItem) -> some View {
        DisclosureGroup(isExpanded: $isRouteBriefExpanded) {
            VStack(alignment: .leading, spacing: 11) {
                if !item.summary.isEmpty {
                    Text(item.summary)
                        .herdrFont(.body)
                        .foregroundStyle(HerdrTheme.mist)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let jira = item.jira {
                    HStack(spacing: 8) {
                        ActiveWorkMetadataChip(
                            title: jira.status.lowercased(),
                            symbol: "checkmark.square",
                            color: HerdrTheme.mauve
                        )
                        .accessibilityLabel("Jira status: \(jira.status)")
                        if let priority = jira.priority, !priority.isEmpty {
                            ActiveWorkMetadataChip(
                                title: priority.lowercased(),
                                symbol: "flag",
                                color: HerdrTheme.working
                            )
                            .accessibilityLabel("Jira priority: \(priority)")
                        }
                        if let issueType = jira.issueType, !issueType.isEmpty {
                            ActiveWorkMetadataChip(title: issueType.lowercased(), symbol: "tag")
                                .accessibilityLabel("Jira issue type: \(issueType)")
                        }
                    }
                }

                if let reason = actionableAttentionReason(for: item) {
                    Label(reason, systemImage: "hand.raised.fill")
                        .herdrFont(.subheadline, weight: .semibold)
                        .foregroundStyle(HerdrTheme.alert)
                        .accessibilityLabel("Needs your attention: \(reason)")
                }

                if let nextAction = item.nextAction, !nextAction.isEmpty {
                    Label(nextAction, systemImage: "arrow.forward.circle.fill")
                        .herdrFont(.subheadline, weight: .semibold)
                        .foregroundStyle(item.needsAttention ? HerdrTheme.alert : HerdrTheme.text)
                }

                HStack(spacing: 10) {
                    if let updatedAt = item.updatedAt {
                        HStack(spacing: 4) {
                            Text("updated")
                            ActiveWorkRelativeTimestamp(value: updatedAt)
                        }
                        .herdrFont(.caption, monospaced: true)
                        .foregroundStyle(HerdrTheme.muted)
                    }
                    Spacer()
                    Text("revision \(item.revision)")
                        .herdrFont(.caption, monospaced: true)
                        .foregroundStyle(HerdrTheme.muted)
                }
            }
            .padding(.top, 12)
        } label: {
            HStack(spacing: 8) {
                Text("Route brief")
                    .herdrFont(.subheadline, weight: .bold)
                    .foregroundStyle(HerdrTheme.text)
                Spacer()
                ActiveWorkReadinessBadge(readiness: item.readiness)
            }
        }
        .tint(HerdrTheme.accent)
        .padding(14)
        .background(HerdrTheme.graphite, in: .rect(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(HerdrTheme.surface.opacity(0.52), lineWidth: 1)
        }
    }

    private func routeDetails(
        _ item: ActiveWorkItem,
        unscopedThreads: [ActiveWorkThread]
    ) -> some View {
        DisclosureGroup(isExpanded: $isRouteDetailsExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(store.stages.enumerated(), id: \.element.id) { index, stage in
                    ActiveWorkRouteStageView(
                        item: item,
                        pipeline: store.pipeline,
                        stage: stage,
                        isLast: index == store.stages.count - 1,
                        openSession: openSession,
                        openURL: openURL
                    )
                    .id("\(item.id)-\(stage.id)")
                }

                if !unscopedThreads.isEmpty {
                    ActiveWorkDiscussionSection(threads: unscopedThreads, openURL: openURL)
                }
            }
            .padding(.top, 14)
        } label: {
            HStack(spacing: 8) {
                Text("Stage details")
                    .herdrFont(.subheadline, weight: .bold)
                    .foregroundStyle(HerdrTheme.text)
                Spacer()
                Text("\(store.stages.count) stages · sessions & discussions")
                    .herdrFont(.caption, monospaced: true)
                    .foregroundStyle(HerdrTheme.muted)
            }
        }
        .tint(HerdrTheme.accent)
        .padding(14)
        .background(HerdrTheme.graphite.opacity(0.58), in: .rect(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(HerdrTheme.surface.opacity(0.4), lineWidth: 1)
        }
    }

    private func focusTitle(for item: ActiveWorkItem) -> String {
        if let key = item.jira?.issueKey, !key.isEmpty {
            return "\(key) · \(item.title)"
        }
        return item.title
    }

    private func actionableAttentionReason(for item: ActiveWorkItem) -> String? {
        guard item.needsAttention,
              let reason = item.attentionReason?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty else { return nil }
        let nextAction = item.nextAction?.trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.caseInsensitiveCompare(nextAction ?? "") == .orderedSame ? nil : reason
    }
}

private struct ActiveWorkFocusHero: View {
    let item: ActiveWorkItem
    let pipeline: ActiveWorkPipeline
    let stages: [ActiveWorkPipelineStage]

    private var agents: [ActiveWorkAgent] {
        ActiveWorkProjection.allAgents(for: item)
    }

    private var activities: [ActiveWorkActivity] {
        Array(ActiveWorkProjection.activity(for: item).prefix(12))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ActiveWorkFocusTrack(item: item, pipeline: pipeline, stages: stages)
                .padding(.top, 22)
                .padding(.bottom, 18)

                HStack(alignment: .top, spacing: 12) {
                    activityPanel
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    castPanel
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
        }
        .padding(18)
        .background(HerdrTheme.graphite)
        .clipShape(.rect(cornerRadius: HerdrTheme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                .strokeBorder(HerdrTheme.mist.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Focus route for \(focusTitle)")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(kindTitle)
                    .herdrFont(size: 9, monospaced: true, weight: .semibold, relativeTo: .caption)
                    .foregroundStyle(HerdrTheme.mist)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(HerdrTheme.elevated.opacity(0.52), in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(HerdrTheme.mist.opacity(0.2), lineWidth: 1)
                    }

                Text(focusTitle)
                    .herdrFont(.title2, weight: .bold)
                    .fontDesign(.rounded)
                    .foregroundStyle(HerdrTheme.text)
                    .fixedSize(horizontal: false, vertical: true)

                Text("\(floorTitle) · \(currentSkillTitle)")
                    .herdrFont(size: 10, monospaced: true, weight: .medium, relativeTo: .caption)
                    .foregroundStyle(HerdrTheme.mist)
                    .lineLimit(1)
                    .help("Floor: \(floorTitle). Current skill: \(currentSkillTitle)")
            }

            Spacer(minLength: 10)

            if !agents.isEmpty {
                ActiveWorkAvatarStack(agents: agents, size: 30, limit: 6)
                    .padding(.top, 2)
            }
        }
    }

    private var activityPanel: some View {
        ActiveWorkFocusPanel(title: "Route activity") {
            if activities.isEmpty {
                Text("No route events yet.")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(activities.enumerated(), id: \.element.id) { index, event in
                        ActiveWorkFocusActivityRow(event: event)
                            .padding(.vertical, 7)
                            .overlay(alignment: .top) {
                                if index > 0 {
                                    Rectangle()
                                        .fill(HerdrTheme.surface.opacity(0.34))
                                        .frame(height: 1)
                                }
                            }
                    }
                }
            }
        }
    }

    private var castPanel: some View {
        ActiveWorkFocusPanel(title: "Traveling cast") {
            if agents.isEmpty {
                Text("No agents are attached yet.")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(agents.enumerated(), id: \.element.id) { index, agent in
                        ActiveWorkFocusCastRow(agent: agent)
                            .padding(.vertical, 7)
                            .overlay(alignment: .top) {
                                if index > 0 {
                                    Rectangle()
                                        .fill(HerdrTheme.surface.opacity(0.34))
                                        .frame(height: 1)
                                }
                            }
                    }
                }
            }
        }
    }

    private var focusTitle: String {
        guard let key = item.jira?.issueKey, !key.isEmpty else { return item.title }
        return "\(key) · \(item.title)"
    }

    private var kindTitle: String {
        displayName(for: item.kind)
    }

    private var currentStage: ActiveWorkPipelineStage? {
        stages.first { $0.key == item.currentStageKey }
    }

    private var currentSkillTitle: String {
        currentStage?.skillName ?? currentStage?.title ?? "idea intake"
    }

    private var floorTitle: String {
        let session = currentStage
            .flatMap { ActiveWorkProjection.sessions(for: item, stage: $0).first }
            ?? item.piSessions.first(where: { $0.detachedAt == nil })
            ?? item.piSessions.first

        if let session {
            let machine = session.machineID ?? "local"
            if let pane = session.paneID, !pane.isEmpty {
                return "\(machine) · \(pane)"
            }
            if let workspace = session.workspaceID, !workspace.isEmpty {
                return "\(machine) · \(workspace)"
            }
            return machine
        }

        if let pane = agents.lazy.compactMap(\.paneID).first {
            return "local · \(pane)"
        }
        return "no active floor"
    }

    private func displayName(for identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

private struct ActiveWorkFocusTrack: View {
    let item: ActiveWorkItem
    let pipeline: ActiveWorkPipeline
    let stages: [ActiveWorkPipelineStage]

    var body: some View {
        if stages.isEmpty {
            Text("The route has no configured stages.")
                .herdrFont(.caption, monospaced: true)
                .foregroundStyle(HerdrTheme.muted)
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
        } else {
            GeometryReader { geometry in
                let spacing: CGFloat = 8
                let minimumStageWidth: CGFloat = 62
                let availableStageWidth = (
                    geometry.size.width - (spacing * CGFloat(max(0, stages.count - 1)))
                ) / CGFloat(stages.count)
                let stageWidth = max(minimumStageWidth, availableStageWidth)
                let trackWidth = stageWidth * CGFloat(stages.count)
                    + spacing * CGFloat(max(0, stages.count - 1))

                ScrollView(.horizontal) {
                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(HerdrTheme.surface)
                            .frame(width: max(0, trackWidth - stageWidth), height: 1)
                            .offset(x: stageWidth / 2, y: 53)

                        HStack(alignment: .top, spacing: spacing) {
                            ForEach(stages) { stage in
                                ActiveWorkFocusTrackStage(
                                    item: item,
                                    pipeline: pipeline,
                                    stage: stage
                                )
                                .frame(width: stageWidth)
                            }
                        }
                    }
                    .frame(width: trackWidth, height: 92, alignment: .topLeading)
                }
                .scrollIndicators(.hidden)
            }
            .frame(height: 92)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(pipeline.title) route")
        }
    }
}

private struct ActiveWorkFocusTrackStage: View {
    let item: ActiveWorkItem
    let pipeline: ActiveWorkPipeline
    let stage: ActiveWorkPipelineStage

    private var progress: ActiveWorkStageProgress {
        ActiveWorkProjection.progress(for: stage, item: item, pipeline: pipeline)
    }

    private var isCurrent: Bool {
        stage.key == item.currentStageKey
    }

    private var agents: [ActiveWorkAgent] {
        ActiveWorkProjection.agents(for: item, stage: stage, pipeline: pipeline)
    }

    private var isCheckpoint: Bool {
        guard let checkpoint = stage.checkpoint?.lowercased() else { return false }
        return !checkpoint.isEmpty && checkpoint != "none"
    }

    private var nodeColor: Color {
        if progress == .complete { return HerdrTheme.signal }
        if progress == .blocked { return HerdrTheme.alert }
        if isCurrent { return HerdrTheme.accent }
        return HerdrTheme.muted
    }

    private var nodeFill: Color {
        if progress == .complete { return HerdrTheme.signal }
        if isCurrent || progress == .blocked { return nodeColor.opacity(0.18) }
        return HerdrTheme.crust
    }

    private var nodeText: String {
        switch progress {
        case .complete: "✓"
        case .skipped: "–"
        default: "\(stage.sequence)"
        }
    }

    private var stageTitle: String {
        switch stage.key {
        case "start-ticket": "Start"
        case "plan": "Plan"
        case "implement": "Implement"
        case "architect-code-review": "Agent review"
        case "proof": "Proof"
        case "code-review-pre-pr": "Pre-PR"
        case "pr": "PR"
        case "pr-triage": "Triage"
        default: stage.shortTitle
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if agents.isEmpty {
                    Color.clear
                } else {
                    ActiveWorkAvatarStack(
                        agents: agents,
                        size: 25,
                        isFuture: progress == .pending,
                        limit: 2
                    )
                }
            }
            .frame(height: 38)

            Text(nodeText)
                .herdrFont(size: 10, monospaced: true, weight: .bold, relativeTo: .caption)
                .foregroundStyle(progress == .complete ? HerdrTheme.ink : (isCurrent || progress == .blocked ? HerdrTheme.text : HerdrTheme.muted))
                .frame(width: 30, height: 30)
                .background {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(nodeFill)
                }
                .overlay {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(
                                nodeColor.opacity(isCurrent || progress == .blocked ? 1 : 0.5),
                                lineWidth: isCurrent ? 1.5 : 1
                            )
                        if isCurrent {
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(nodeColor.opacity(0.08), lineWidth: 5)
                                .padding(-4)
                        }
                    }
                }

            HStack(spacing: 2) {
                Text(stageTitle)
                    .lineLimit(1)
                if isCheckpoint {
                    Image(systemName: "star.fill")
                        .herdrFont(size: 7, weight: .bold, relativeTo: .caption2)
                        .foregroundStyle(HerdrTheme.alert)
                }
            }
            .herdrFont(size: 8, monospaced: true, weight: .semibold, relativeTo: .caption2)
            .foregroundStyle(isCurrent ? HerdrTheme.text : (progress == .complete ? HerdrTheme.mist : HerdrTheme.muted))
            .frame(maxWidth: .infinity)
            .padding(.top, 7)
        }
        .help("\(stage.title) · \(stage.skillName ?? progress.title)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Stage \(stage.sequence), \(stage.title), \(progress.title)\(isCheckpoint ? ", human checkpoint" : "")")
        .accessibilityIdentifier("active-work-stage-\(stage.key)")
    }
}

private struct ActiveWorkFocusPanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .herdrFont(.subheadline, weight: .bold)
                .foregroundStyle(HerdrTheme.text)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(HerdrTheme.crust.opacity(0.48), in: .rect(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(HerdrTheme.mist.opacity(0.16), lineWidth: 1)
        }
    }
}

private struct ActiveWorkFocusActivityRow: View {
    let event: ActiveWorkActivity

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if event.occurredAt != nil || event.createdAt != nil {
                    ActiveWorkRelativeTimestamp(value: event.occurredAt ?? event.createdAt)
                } else {
                    Text("event")
                }
            }
            .herdrFont(size: 9, monospaced: true, weight: .semibold, relativeTo: .caption)
            .foregroundStyle(HerdrTheme.muted)
            .frame(width: 42, alignment: .leading)

            Text(event.source ?? event.actorKind ?? event.kind)
                .herdrFont(size: 9, monospaced: true, weight: .semibold, relativeTo: .caption)
                .foregroundStyle(HerdrTheme.accent)
                .lineLimit(1)
                .frame(width: 72, alignment: .leading)

            Text(event.message)
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.mist)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ActiveWorkFocusCastRow: View {
    let agent: ActiveWorkAgent

    private var isQueued: Bool {
        let linkStates = ([agent.linkState] + agent.stageLinks.map(\.linkState))
            .compactMap { $0?.lowercased() }
        if linkStates.contains(where: { $0.contains("active") || $0.contains("working") }) {
            return false
        }
        return agent.status == .idle
            || linkStates.contains(where: { $0.contains("queued") || $0.contains("waiting") })
    }

    private var statusTitle: String {
        if isQueued { return "queued" }
        if agent.status == .blocked { return "checkpoint" }
        if agent.status == .working { return "active" }
        return agent.status.compactTitle.lowercased()
    }

    private var statusColor: Color {
        if isQueued { return HerdrTheme.mist }
        return agent.status.color
    }

    private var roleTitle: String {
        agent.roleLabel ?? agent.linkRole ?? agent.kind ?? "attached agent"
    }

    var body: some View {
        HStack(spacing: 9) {
            ActiveWorkAgentAvatar(agent: agent, size: 25, isFuture: isQueued)

            VStack(alignment: .leading, spacing: 2) {
                Text(agent.displayName)
                    .herdrFont(.caption, weight: .bold)
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(1)
                Text(isQueued ? "joins at next stage" : roleTitle.lowercased())
                    .herdrFont(size: 9, monospaced: true, weight: .medium, relativeTo: .caption)
                    .foregroundStyle(HerdrTheme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 5)

            Text(statusTitle)
                .herdrFont(size: 9, monospaced: true, weight: .semibold, relativeTo: .caption)
                .foregroundStyle(statusColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(statusColor.opacity(0.08), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(statusColor.opacity(0.28), lineWidth: 1)
                }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ActiveWorkTransitionCard: View {
    let item: ActiveWorkItem
    let currentStage: ActiveWorkPipelineStage?
    let nextStage: ActiveWorkPipelineStage
    let isControlEnabled: Bool
    let transition: (ActiveWorkItem, ActiveWorkPipelineStage) async throws -> Void

    @State private var isMoving = false
    @State private var didMove = false
    @State private var errorMessage: String?
    @State private var isShowingApprovalConfirmation = false

    private var targetHasHumanCheckpoint: Bool {
        guard let checkpoint = nextStage.checkpoint?.lowercased() else { return false }
        return !checkpoint.isEmpty && checkpoint != "none"
    }

    private var approvesCurrentCheckpoint: Bool {
        guard let currentStage else { return false }
        let state = ActiveWorkProjection.stageState(for: currentStage, item: item)
        let checkpointState = state?.checkpointState?.lowercased()
        return state?.attention == .human || checkpointState == "pending" || checkpointState == "changes_requested"
    }

    private var accentColor: Color {
        approvesCurrentCheckpoint || targetHasHumanCheckpoint ? HerdrTheme.working : HerdrTheme.accent
    }

    private var actionTitle: String {
        guard approvesCurrentCheckpoint else { return "Move to next stage" }
        return "Approve \(currentStage?.shortTitle ?? "checkpoint")"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: approvesCurrentCheckpoint || targetHasHumanCheckpoint ? "person.crop.circle.badge.checkmark" : "arrow.right.circle.fill")
                .herdrFont(.title3, weight: .bold)
                .foregroundStyle(accentColor)

            VStack(alignment: .leading, spacing: 4) {
                Text("Next: \(nextStage.title)")
                    .herdrFont(.subheadline, weight: .bold)
                    .foregroundStyle(HerdrTheme.text)
                Text(approvesCurrentCheckpoint
                     ? "This explicitly approves \(currentStage?.title ?? "the current checkpoint") before advancing."
                     : targetHasHumanCheckpoint
                         ? "The next stage starts a human checkpoint before work continues."
                         : "Advance the shared board and keep attached agents on the route.")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.mist)
                if let errorMessage {
                    Text(errorMessage)
                        .herdrFont(.caption, monospaced: true)
                        .foregroundStyle(HerdrTheme.alert)
                }
            }

            Spacer(minLength: 10)

            Button {
                if approvesCurrentCheckpoint {
                    isShowingApprovalConfirmation = true
                } else {
                    Task { await move() }
                }
            } label: {
                Group {
                    if isMoving {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(didMove ? "Moved" : actionTitle, systemImage: didMove ? "checkmark" : "arrow.right")
                    }
                }
                .frame(minWidth: 132, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .tint(accentColor)
            .disabled(isMoving || didMove || !isControlEnabled)
            .help(isControlEnabled ? actionTitle : "Control access is required to advance work")
            .accessibilityIdentifier("active-work-transition-\(item.id)")
        }
        .padding(13)
        .background(HerdrTheme.elevated.opacity(0.72))
        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(accentColor.opacity(0.28), lineWidth: 1)
        }
        .confirmationDialog(
            "Approve \(currentStage?.title ?? "this checkpoint")?",
            isPresented: $isShowingApprovalConfirmation,
            titleVisibility: .visible
        ) {
            Button("Approve and move to \(nextStage.title)") {
                Task { await move() }
            }
        } message: {
            Text("Herdr will record the current human checkpoint as approved and advance the shared route.")
        }
    }

    @MainActor
    private func move() async {
        guard !isMoving, !didMove else { return }
        isMoving = true
        errorMessage = nil
        defer { isMoving = false }
        do {
            try await transition(item, nextStage)
            didMove = true
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ActiveWorkLifecycleCard: View {
    enum Action {
        case complete
        case archive

        var lifecycle: String { self == .complete ? "done" : "archived" }
        var title: String { self == .complete ? "Complete this route" : "Archive completed work" }
        var detail: String {
            self == .complete
                ? "Mark the final PR Triage stage complete. The item remains visible until you archive it."
                : "Remove this completed item from Active Work. Its history stays in Herdr's durable store."
        }
        var buttonTitle: String { self == .complete ? "Mark complete" : "Archive" }
        var symbol: String { self == .complete ? "checkmark.seal.fill" : "archivebox.fill" }
        var color: Color { self == .complete ? HerdrTheme.signal : HerdrTheme.mist }
    }

    let item: ActiveWorkItem
    let action: Action
    let isControlEnabled: Bool
    let setLifecycle: (ActiveWorkItem, String) async throws -> Void

    @State private var isWorking = false
    @State private var didApply = false
    @State private var isShowingConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: action.symbol)
                .herdrFont(.title3, weight: .bold)
                .foregroundStyle(action.color)
            VStack(alignment: .leading, spacing: 4) {
                Text(action.title)
                    .herdrFont(.subheadline, weight: .bold)
                    .foregroundStyle(HerdrTheme.text)
                Text(action.detail)
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.mist)
                if let errorMessage {
                    Text(errorMessage)
                        .herdrFont(.caption, monospaced: true)
                        .foregroundStyle(HerdrTheme.alert)
                }
            }
            Spacer(minLength: 10)
            Button(didApply ? (action == .complete ? "Completed" : "Archived") : action.buttonTitle, systemImage: didApply ? "checkmark" : action.symbol) {
                isShowingConfirmation = true
            }
            .buttonStyle(.borderedProminent)
            .tint(action.color)
            .disabled(isWorking || didApply || !isControlEnabled)
            .help(isControlEnabled ? action.buttonTitle : "Control access is required to update work")
            .accessibilityIdentifier("active-work-\(action.lifecycle)-\(item.id)")
        }
        .padding(13)
        .background(HerdrTheme.elevated.opacity(0.72))
        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(action.color.opacity(0.28), lineWidth: 1)
        }
        .confirmationDialog(action.title, isPresented: $isShowingConfirmation, titleVisibility: .visible) {
            Button(action.buttonTitle, role: action == .archive ? .destructive : nil) {
                Task { await runAction() }
            }
        } message: {
            Text(action.detail)
        }
    }

    @MainActor
    private func runAction() async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await setLifecycle(item, action.lifecycle)
            didApply = true
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ActiveWorkRouteStageView: View {
    let item: ActiveWorkItem
    let pipeline: ActiveWorkPipeline
    let stage: ActiveWorkPipelineStage
    let isLast: Bool
    let openSession: (ActiveWorkPiSession) -> Void
    let openURL: (URL) -> Void

    @State private var isExpanded: Bool

    init(
        item: ActiveWorkItem,
        pipeline: ActiveWorkPipeline,
        stage: ActiveWorkPipelineStage,
        isLast: Bool,
        openSession: @escaping (ActiveWorkPiSession) -> Void,
        openURL: @escaping (URL) -> Void
    ) {
        self.item = item
        self.pipeline = pipeline
        self.stage = stage
        self.isLast = isLast
        self.openSession = openSession
        self.openURL = openURL
        _isExpanded = State(initialValue: stage.key == item.currentStageKey)
    }

    private var progress: ActiveWorkStageProgress {
        ActiveWorkProjection.progress(for: stage, item: item, pipeline: pipeline)
    }

    private var state: ActiveWorkStageState? {
        ActiveWorkProjection.stageState(for: stage, item: item)
    }

    private var agents: [ActiveWorkAgent] {
        ActiveWorkProjection.agents(for: item, stage: stage, pipeline: pipeline)
    }

    private var sessions: [ActiveWorkPiSession] {
        ActiveWorkProjection.sessions(for: item, stage: stage)
    }

    private var threads: [ActiveWorkThread] {
        ActiveWorkProjection.threads(for: item, stage: stage)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Image(systemName: progress.symbol)
                    .herdrFont(size: 11, weight: .bold, relativeTo: .caption)
                    .foregroundStyle(progress.foregroundColor)
                    .frame(width: 28, height: 28)
                    .background(progress.color.opacity(progress == .pending ? 0.08 : 0.16), in: Circle())
                    .overlay { Circle().strokeBorder(progress.color.opacity(0.72), lineWidth: 1) }
                if !isLast {
                    Rectangle()
                        .fill(progress.color.opacity(progress == .pending ? 0.2 : 0.55))
                        .frame(width: 2, height: 42)
                }
            }
            .accessibilityHidden(true)

            GlassCard(radius: HerdrTheme.compactRadius) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 7) {
                                Text("\(stage.sequence)")
                                    .herdrFont(.caption, monospaced: true, weight: .bold)
                                    .foregroundStyle(progress.color)
                                Text(stage.phase.lowercased())
                                    .herdrFont(.caption2, monospaced: true, weight: .bold)
                                    .foregroundStyle(HerdrTheme.muted)
                            }
                            Text(stage.title)
                                .herdrFont(.headline, weight: .bold)
                                .foregroundStyle(HerdrTheme.text)
                        }
                        Spacer(minLength: 8)
                        ActiveWorkAvatarStack(agents: agents, size: 25, isFuture: progress == .pending, limit: 5)
                        ActiveWorkMetadataChip(title: progress.title.lowercased(), symbol: progress.symbol, color: progress.color)
                    }

                    if let summary = state?.summary, !summary.isEmpty {
                        Text(summary)
                            .herdrFont(.subheadline)
                            .foregroundStyle(HerdrTheme.mist)
                    }

                    HStack(spacing: 8) {
                        if let skillName = stage.skillName, !skillName.isEmpty {
                            ActiveWorkMetadataChip(title: skillName, symbol: "sparkles", color: HerdrTheme.mauve)
                        }
                        if let checkpoint = stage.checkpoint, !checkpoint.isEmpty, checkpoint.lowercased() != "none" {
                            ActiveWorkMetadataChip(title: checkpoint, symbol: "person.crop.circle.badge.checkmark", color: HerdrTheme.working)
                        }
                        if let checkpointState = state?.checkpointState, !checkpointState.isEmpty {
                            ActiveWorkMetadataChip(title: checkpointState, symbol: "checkmark.seal", color: HerdrTheme.signal)
                        }
                    }

                    if !sessions.isEmpty || !threads.isEmpty {
                        DisclosureGroup(isExpanded: $isExpanded) {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(sessions) { session in
                                    sessionRow(session)
                                }
                                ForEach(threads) { thread in
                                    threadRow(thread)
                                }
                            }
                            .padding(.top, 8)
                        } label: {
                            Text("\(sessions.count) session\(sessions.count == 1 ? "" : "s") · \(threads.count) thread\(threads.count == 1 ? "" : "s")")
                                .herdrFont(.caption, monospaced: true, weight: .bold)
                                .foregroundStyle(HerdrTheme.mist)
                        }
                        .tint(HerdrTheme.accent)
                    }
                }
                .padding(13)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Stage \(stage.sequence), \(stage.title), \(progress.title)")
        }
        .accessibilityIdentifier("active-work-stage-detail-\(stage.key)")
        .onChange(of: item.currentStageKey) { _, newStageKey in
            if newStageKey == stage.key {
                isExpanded = true
            }
        }
    }

    private func sessionRow(_ session: ActiveWorkPiSession) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "terminal")
                .foregroundStyle(HerdrTheme.accent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .herdrFont(.subheadline, weight: .semibold)
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(1)
                Text([session.provider, session.model, session.status].compactMap { $0 }.joined(separator: " · "))
                    .herdrFont(.caption, monospaced: true)
                    .foregroundStyle(HerdrTheme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if session.paneID != nil {
                Button {
                    openSession(session)
                } label: {
                    Label("Open", systemImage: "arrow.up.right.square")
                        .herdrFont(.caption, weight: .bold)
                }
                .buttonStyle(.plain)
                .foregroundStyle(HerdrTheme.accent)
                .accessibilityLabel("Open Pi session \(session.title)")
                .accessibilityIdentifier("active-work-open-pane-\(session.id)")
            }
        }
        .padding(9)
        .background(HerdrTheme.ink.opacity(0.58))
        .clipShape(.rect(cornerRadius: 8))
    }

    private func threadRow(_ thread: ActiveWorkThread) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "bubble.left.and.bubble.right")
                .foregroundStyle(HerdrTheme.mauve)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.title)
                    .herdrFont(.subheadline, weight: .semibold)
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(1)
                if let snippet = thread.snippet, !snippet.isEmpty {
                    Text(snippet)
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let url = thread.browserURL {
                Button {
                    openURL(url)
                } label: {
                    Label("Open", systemImage: "arrow.up.right.square")
                        .herdrFont(.caption, weight: .bold)
                }
                .buttonStyle(.plain)
                .foregroundStyle(HerdrTheme.mauve)
                .accessibilityLabel("Open Buzz thread \(thread.title)")
                .accessibilityIdentifier("active-work-open-buzz-\(thread.id)")
            }
        }
        .padding(9)
        .background(HerdrTheme.ink.opacity(0.58))
        .clipShape(.rect(cornerRadius: 8))
    }
}

private struct ActiveWorkDiscussionSection: View {
    let threads: [ActiveWorkThread]
    let openURL: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HerdrSectionLabel(title: "BUZZ DISCUSSIONS", detail: "ticket-level")
            ForEach(threads) { thread in
                HStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .foregroundStyle(HerdrTheme.mauve)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(thread.title)
                            .herdrFont(.subheadline, weight: .bold)
                            .foregroundStyle(HerdrTheme.text)
                        if let snippet = thread.snippet, !snippet.isEmpty {
                            Text(snippet)
                                .herdrFont(.caption)
                                .foregroundStyle(HerdrTheme.muted)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    if let url = thread.browserURL {
                        Button("Open thread", systemImage: "arrow.up.right.square") {
                            openURL(url)
                        }
                        .buttonStyle(.plain)
                        .labelStyle(.iconOnly)
                        .foregroundStyle(HerdrTheme.mauve)
                        .help("Open this Buzz discussion")
                        .accessibilityLabel("Open Buzz thread \(thread.title)")
                        .accessibilityIdentifier("active-work-open-buzz-\(thread.id)")
                    }
                }
                .padding(11)
                .background(HerdrTheme.elevated.opacity(0.66), in: .rect(cornerRadius: HerdrTheme.compactRadius))
            }
        }
    }
}

private struct ActiveWorkActivitySection: View {
    let item: ActiveWorkItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HerdrSectionLabel(title: "ROUTE ACTIVITY", detail: "latest first")
            ForEach(ActiveWorkProjection.activity(for: item).prefix(12)) { event in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: event.kind.lowercased().contains("complete") ? "checkmark.circle.fill" : "circle.fill")
                        .herdrFont(.caption)
                        .foregroundStyle(event.kind.lowercased().contains("complete") ? HerdrTheme.signal : HerdrTheme.accent)
                        .frame(width: 18)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.message)
                            .herdrFont(.subheadline)
                            .foregroundStyle(HerdrTheme.text)
                        HStack(spacing: 5) {
                            Text(event.source ?? event.kind)
                            if let occurredAt = event.occurredAt ?? event.createdAt {
                                Text("·")
                                ActiveWorkRelativeTimestamp(value: occurredAt)
                            }
                        }
                        .herdrFont(.caption, monospaced: true)
                        .foregroundStyle(HerdrTheme.muted)
                    }
                }
                .padding(.vertical, 5)
            }
        }
        .padding(.top, 5)
    }
}
