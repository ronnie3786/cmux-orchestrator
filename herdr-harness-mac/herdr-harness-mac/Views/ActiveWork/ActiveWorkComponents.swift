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
                    Circle().strokeBorder(avatarColor.opacity(isFuture ? 0.48 : 0.9), lineWidth: 1.5)
                }

            Circle()
                .fill(agent.status.color)
                .frame(width: max(7, size * 0.27), height: max(7, size * 0.27))
                .overlay { Circle().strokeBorder(HerdrTheme.graphite, lineWidth: 1.5) }
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
        HStack(spacing: -7) {
            ForEach(Array(agents.prefix(limit))) { agent in
                ActiveWorkAgentAvatar(agent: agent, size: size, isFuture: isFuture)
            }
            if agents.count > limit {
                Text("+\(agents.count - limit)")
                    .herdrFont(size: max(8, size * 0.31), monospaced: true, weight: .bold, relativeTo: .caption)
                    .foregroundStyle(HerdrTheme.mist)
                    .frame(width: size, height: size)
                    .background(HerdrTheme.elevated, in: Circle())
                    .overlay { Circle().strokeBorder(HerdrTheme.surface, lineWidth: 1) }
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
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                        stageNode(
                            stage,
                            index: index,
                            width: max(88, (geometry.size.width - 4) / CGFloat(max(stages.count, 1)))
                        )
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.hidden)
        }
        .frame(height: 80)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(pipeline.title) route")
    }

    private var stages: [ActiveWorkPipelineStage] {
        ActiveWorkProjection.orderedStages(in: pipeline)
    }

    private func stageNode(_ stage: ActiveWorkPipelineStage, index: Int, width: CGFloat) -> some View {
        let progress = ActiveWorkProjection.progress(for: stage, item: item, pipeline: pipeline)
        let isCurrent = stage.key == item.currentStageKey
        let isNext = ActiveWorkProjection.nextStage(for: item, pipeline: pipeline)?.key == stage.key
        let travelers = (isCurrent || isNext)
            ? ActiveWorkProjection.agents(for: item, stage: stage, pipeline: pipeline)
            : []

        return VStack(spacing: 6) {
            Group {
                if travelers.isEmpty {
                    Color.clear.frame(height: 25)
                } else {
                    ActiveWorkAvatarStack(agents: travelers, size: 24, isFuture: isNext, limit: 3)
                }
            }
            .frame(height: 25)

            HStack(spacing: 0) {
                Rectangle()
                    .fill(index == 0 ? Color.clear : connectorColor(before: index))
                    .frame(height: 2)
                Image(systemName: progress.symbol)
                    .herdrFont(size: 11, weight: .bold, relativeTo: .caption)
                    .foregroundStyle(progress.foregroundColor)
                    .frame(width: 24, height: 24)
                    .background(progress.color.opacity(progress == .pending ? 0.08 : 0.16), in: Circle())
                    .overlay { Circle().strokeBorder(progress.color.opacity(0.7), lineWidth: 1) }
                Rectangle()
                    .fill(index == stages.count - 1 ? Color.clear : progress.color.opacity(progress == .pending ? 0.22 : 0.62))
                    .frame(height: 2)
            }

            Text(stage.shortTitle)
                .herdrFont(.caption, monospaced: true, weight: isCurrent ? .bold : .regular)
                .foregroundStyle(isCurrent ? HerdrTheme.text : HerdrTheme.mist)
                .lineLimit(1)
        }
        .frame(width: width)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stage.title), \(progress.title)\(isNext ? ", next" : "")")
    }

    private func connectorColor(before index: Int) -> Color {
        guard stages.indices.contains(index - 1) else { return .clear }
        let previous = ActiveWorkProjection.progress(for: stages[index - 1], item: item, pipeline: pipeline)
        return previous.color.opacity(previous == .pending ? 0.22 : 0.62)
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
