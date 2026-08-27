import SwiftUI

struct ActiveWorkAgentAvatar: View {
    let agent: ActiveWorkAgent
    var size: CGFloat = 28
    var isFuture = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            avatarContent
                .frame(width: size, height: size)
                .background(avatarColor.opacity(0.22), in: Circle())
                .clipShape(Circle())
                .overlay {
                    Circle().strokeBorder(HerdrTheme.ink, lineWidth: 2)
                }

            Circle()
                .fill(agent.status.color)
                .frame(width: max(7, size * 0.27), height: max(7, size * 0.27))
                .overlay { Circle().strokeBorder(HerdrTheme.ink, lineWidth: 1.5) }
        }
        .opacity(isFuture ? 0.58 : 1)
        .help("\(agent.displayName) · \(agent.roleLabel ?? agent.linkRole ?? agent.kind ?? "agent") · \(agent.status.title)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(agent.displayName), \(agent.roleLabel ?? agent.kind ?? "agent"), \(agent.status.title)")
    }

    @ViewBuilder
    private var avatarContent: some View {
        if let url = agent.remoteAvatarURL {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    initials
                }
            }
        } else {
            initials
        }
    }

    private var initials: some View {
        Text(agent.initials)
            .herdrFont(size: max(8, size * 0.34), monospaced: true, weight: .bold, relativeTo: .caption)
            .foregroundStyle(HerdrTheme.text)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var avatarColor: Color {
        let palette = [HerdrTheme.accent, HerdrTheme.mauve, HerdrTheme.signal, HerdrTheme.working, HerdrTheme.code]
        let scalarTotal = agent.id.unicodeScalars.reduce(0) { partial, scalar in
            partial &+ Int(scalar.value)
        }
        return palette[abs(scalarTotal) % palette.count]
    }
}

struct ActiveWorkAvatarStack: View {
    let agents: [ActiveWorkAgent]
    var size: CGFloat = 28
    var isFuture = false
    var limit = 4

    var body: some View {
        HStack(spacing: -6) {
            ForEach(agents.prefix(limit)) { agent in
                ActiveWorkAgentAvatar(agent: agent, size: size, isFuture: isFuture)
            }
            if agents.count > limit {
                Text("+\(agents.count - limit)")
                    .herdrFont(size: max(8, size * 0.31), monospaced: true, weight: .bold, relativeTo: .caption)
                    .foregroundStyle(HerdrTheme.mist)
                    .frame(width: size, height: size)
                    .background(HerdrTheme.elevated, in: Circle())
                    .overlay { Circle().strokeBorder(HerdrTheme.ink, lineWidth: 2) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(agents.count) attached agent\(agents.count == 1 ? "" : "s")")
    }
}

struct ActiveWorkPipelineRail: View {
    let item: ActiveWorkItem
    let pipeline: ActiveWorkPipeline

    var body: some View {
        Group {
            if item.currentStageKey == nil {
                ideaPreflight
            } else if stages.isEmpty {
                Text("Pipeline stages unavailable")
                    .herdrFont(size: 10, monospaced: true, relativeTo: .caption)
                    .foregroundStyle(HerdrTheme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    stageRail(width: geometry.size.width)
                }
            }
        }
        .frame(height: item.currentStageKey == nil ? 58 : 63)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(pipeline.title) route")
    }

    private var stages: [ActiveWorkPipelineStage] {
        ActiveWorkProjection.orderedStages(in: pipeline)
    }

    private func stageRail(width: CGFloat) -> some View {
        let gap: CGFloat = 5
        let totalGap = gap * CGFloat(max(stages.count - 1, 0))
        let stageWidth = max(0, (width - totalGap) / CGFloat(max(stages.count, 1)))

        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(HerdrTheme.surface)
                .frame(height: 1)
                .padding(.horizontal, width * 0.05)
                .offset(y: 38)

            HStack(alignment: .top, spacing: gap) {
                ForEach(stages.enumerated(), id: \.element.id) { index, stage in
                    stageNode(stage, index: index, width: stageWidth)
                }
            }
        }
    }

    private func stageNode(_ stage: ActiveWorkPipelineStage, index: Int, width: CGFloat) -> some View {
        let progress = ActiveWorkProjection.progress(for: stage, item: item, pipeline: pipeline)
        let isCurrent = stage.key == item.currentStageKey
        let currentSequence = stages.first(where: { $0.key == item.currentStageKey })?.sequence
        let isFuture = currentSequence.map { stage.sequence > $0 } ?? false
        let travelers = ActiveWorkProjection.agents(for: item, stage: stage, pipeline: pipeline)

        return VStack(spacing: 0) {
            Group {
                if travelers.isEmpty {
                    Color.clear
                } else {
                    ActiveWorkAvatarStack(agents: travelers, size: 25, isFuture: isFuture, limit: 3)
                }
            }
            .frame(height: 31)

            Text(progress == .complete ? "✓" : "\(index + 1)")
                .herdrFont(size: 8, monospaced: true, weight: .bold, relativeTo: .caption)
                .foregroundStyle(nodeForeground(progress: progress, isCurrent: isCurrent))
                .frame(width: isCurrent ? 19 : 15, height: isCurrent ? 19 : 15)
                .background(
                    nodeBackground(progress: progress, isCurrent: isCurrent),
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(
                            nodeBorder(progress: progress, isCurrent: isCurrent),
                            lineWidth: isCurrent ? 1.5 : 1
                        )
                }
                .offset(y: isCurrent ? -2 : 0)
                .frame(height: 19, alignment: .top)

            HStack(spacing: 2) {
                Text(stageDisplayName(stage))
                    .foregroundStyle(stageNameColor(progress: progress, isCurrent: isCurrent))
                if isCheckpoint(stage) {
                    Text("★")
                        .foregroundStyle(HerdrTheme.alert)
                }
            }
                .herdrFont(size: 8, monospaced: true, weight: .semibold, relativeTo: .caption)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
        }
        .frame(width: width)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stage.title), \(progress.title)\(isCheckpoint(stage) ? ", human checkpoint" : "")")
    }

    private var ideaPreflight: some View {
        HStack(spacing: 9) {
            ActiveWorkAvatarStack(
                agents: ActiveWorkProjection.allAgents(for: item).filter { $0.detachedAt == nil },
                size: 28,
                limit: 4
            )

            VStack(alignment: .leading, spacing: 2) {
                Text("Idea intake, before the ticket pipeline")
                    .herdrFont(size: 11, weight: .bold, relativeTo: .caption)
                    .foregroundStyle(HerdrTheme.mauve)
                    .lineLimit(1)
                Text("Explore first. No worktree until a prototype decision is approved.")
                    .herdrFont(size: 10, relativeTo: .caption)
                    .foregroundStyle(HerdrTheme.mist)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(HerdrTheme.mauve.opacity(0.045))
        .clipShape(.rect(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(
                    HerdrTheme.mauve.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        }
    }

    private func stageDisplayName(_ stage: ActiveWorkPipelineStage) -> String {
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

    private func isCheckpoint(_ stage: ActiveWorkPipelineStage) -> Bool {
        guard let checkpoint = stage.checkpoint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else { return false }
        return !checkpoint.isEmpty && !["none", "false", "no"].contains(checkpoint)
    }

    private func nodeForeground(progress: ActiveWorkStageProgress, isCurrent: Bool) -> Color {
        if isCurrent { return HerdrTheme.text }
        if progress == .complete { return HerdrTheme.ink }
        return HerdrTheme.muted
    }

    private func nodeBackground(progress: ActiveWorkStageProgress, isCurrent: Bool) -> Color {
        if isCurrent {
            return (item.needsAttention ? HerdrTheme.alert : HerdrTheme.accent).opacity(
                item.needsAttention ? 0.18 : 0.22
            )
        }
        if progress == .complete { return HerdrTheme.signal }
        return HerdrTheme.crust
    }

    private func nodeBorder(progress: ActiveWorkStageProgress, isCurrent: Bool) -> Color {
        if isCurrent { return item.needsAttention ? HerdrTheme.alert : HerdrTheme.accent }
        if progress == .complete { return HerdrTheme.signal }
        return HerdrTheme.mist.opacity(0.38)
    }

    private func stageNameColor(progress: ActiveWorkStageProgress, isCurrent: Bool) -> Color {
        if isCurrent { return HerdrTheme.text }
        if progress == .complete { return HerdrTheme.mist }
        return HerdrTheme.muted
    }
}

struct ActiveWorkReadinessBadge: View {
    let readiness: ActiveWorkReadiness

    var body: some View {
        Label(readiness.title, systemImage: readiness.symbol)
            .herdrFont(.caption, weight: .bold)
            .foregroundStyle(readiness.color)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(readiness.color.opacity(0.1), in: Capsule())
            .overlay { Capsule().strokeBorder(readiness.color.opacity(0.25), lineWidth: 1) }
            .accessibilityLabel("Setup status: \(readiness.title)")
    }
}

struct ActiveWorkMetadataChip: View {
    let title: String
    let symbol: String
    var color = HerdrTheme.mist

    var body: some View {
        Label(title, systemImage: symbol)
            .herdrFont(.caption, monospaced: true)
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(HerdrTheme.elevated.opacity(0.66), in: Capsule())
    }
}

struct ActiveWorkErrorBanner: View {
    let message: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text("Active Work could not refresh")
                    .herdrFont(.subheadline, weight: .bold)
                Text(message)
                    .herdrFont(.caption, monospaced: true)
                    .textSelection(.enabled)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(HerdrTheme.alert)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HerdrTheme.alert.opacity(0.1))
        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
        .accessibilityIdentifier("active-work-refresh-error")
    }
}

struct ActiveWorkRelativeTimestamp: View {
    let value: String?

    var body: some View {
        if let date = value.flatMap(HerdrTimestamp.date(from:)) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(HerdrTimestamp.compactAge(since: date, now: context.date))
            }
            .accessibilityLabel(HerdrTimestamp.spokenAge(since: date))
        }
    }
}

extension ActiveWorkStageProgress {
    var title: String {
        switch self {
        case .pending: "Pending"
        case .active: "Current"
        case .complete: "Complete"
        case .blocked: "Needs you"
        case .skipped: "Skipped"
        case .unknown: "Unknown"
        }
    }

    var symbol: String {
        switch self {
        case .pending: "circle"
        case .active: "circle.fill"
        case .complete: "checkmark"
        case .blocked: "exclamationmark"
        case .skipped: "minus"
        case .unknown: "questionmark"
        }
    }

    var color: Color {
        switch self {
        case .pending: HerdrTheme.muted
        case .active: HerdrTheme.accent
        case .complete: HerdrTheme.signal
        case .blocked: HerdrTheme.alert
        case .skipped: HerdrTheme.muted
        case .unknown: HerdrTheme.surface
        }
    }

    var foregroundColor: Color {
        self == .pending || self == .unknown ? HerdrTheme.mist : color
    }
}

extension ActiveWorkReadiness {
    var symbol: String {
        switch self {
        case .buzzSetupNext: "bubble.left.and.bubble.right"
        case .driverSetupNext: "person.crop.circle.badge.plus"
        case .ready: "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .buzzSetupNext: HerdrTheme.mauve
        case .driverSetupNext: HerdrTheme.working
        case .ready: HerdrTheme.signal
        }
    }
}
