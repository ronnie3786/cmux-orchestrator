import SwiftUI

struct ActiveWorkFocusRouteView: View {
    @Bindable var store: ActiveWorkStore
    let isControlEnabled: Bool
    let openSession: (ActiveWorkPiSession) -> Void
    let openURL: (URL) -> Void
    let transition: (ActiveWorkItem, ActiveWorkPipelineStage) async throws -> Void
    let setLifecycle: (ActiveWorkItem, String) async throws -> Void

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
                        HStack(spacing: 0) {
                            itemList
                                .frame(width: min(286, max(238, geometry.size.width * 0.25)))
                            Rectangle()
                                .fill(HerdrTheme.surface.opacity(0.72))
                                .frame(width: 1)
                            detail
                        }
                    } else {
                        VStack(spacing: 0) {
                            compactItemPicker
                            Rectangle()
                                .fill(HerdrTheme.surface.opacity(0.72))
                                .frame(height: 1)
                            detail
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("active-work-focus-route")
    }

    private var itemList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                HerdrSectionLabel(title: "ACTIVE WORK", detail: "\(store.items.count)")
                    .padding(.bottom, 4)
                ForEach(store.items) { item in
                    focusItemButton(item, compact: false)
                }
            }
            .padding(14)
        }
        .background(HerdrTheme.graphite.opacity(0.52))
        .scrollIndicators(.hidden)
    }

    private var compactItemPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(store.items) { item in
                    focusItemButton(item, compact: true)
                        .frame(width: 210)
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
        let stage = store.pipeline.stages.first(where: { $0.key == item.currentStageKey })

        return Button {
            store.select(item.id)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(status.color)
                    .frame(width: 3, height: compact ? 42 : 52)

                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title)
                        .herdrFont(.subheadline, weight: .bold)
                        .foregroundStyle(HerdrTheme.text)
                        .lineLimit(compact ? 1 : 2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 5) {
                        if let jira = item.jira {
                            Text(jira.issueKey)
                        }
                        if let stage {
                            Text(stage.shortTitle.lowercased())
                        }
                    }
                    .herdrFont(.caption, monospaced: true)
                    .foregroundStyle(HerdrTheme.mist)
                    .lineLimit(1)

                    if !compact {
                        ActiveWorkAvatarStack(
                            agents: ActiveWorkProjection.allAgents(for: item),
                            size: 21,
                            limit: 4
                        )
                    }
                }

                Spacer(minLength: 3)
                if isSelected {
                    Image(systemName: "chevron.right")
                        .herdrFont(.caption, weight: .bold)
                        .foregroundStyle(HerdrTheme.accent)
                        .padding(.top, 3)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? HerdrTheme.elevated : HerdrTheme.ink.opacity(0.36))
            .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
            .overlay {
                RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                    .strokeBorder(isSelected ? HerdrTheme.accent.opacity(0.62) : HerdrTheme.surface.opacity(0.62), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title), \(status.title)")
        .accessibilityHint("Shows this work item's route")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("active-work-focus-item-\(item.id)")
    }

    @ViewBuilder
    private var detail: some View {
        if let item = store.selectedItem {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 15) {
                    detailHeader(item)

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

                    HerdrSectionLabel(title: "FOCUS ROUTE", detail: "\(store.stages.count) stages")

                    ForEach(Array(store.stages.enumerated()), id: \.element.id) { index, stage in
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

                    let unscopedThreads = item.threads.filter { $0.stageID == nil && $0.stageKey == nil }
                    if !unscopedThreads.isEmpty {
                        ActiveWorkDiscussionSection(threads: unscopedThreads, openURL: openURL)
                    }

                    if !item.activity.isEmpty {
                        ActiveWorkActivitySection(item: item)
                    }
                }
                .frame(maxWidth: 840, alignment: .leading)
                .padding(.horizontal, HerdrTheme.pagePadding)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func detailHeader(_ item: ActiveWorkItem) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 7) {
                            if let jira = item.jira {
                                Text(jira.issueKey)
                                    .foregroundStyle(HerdrTheme.mauve)
                            }
                            Text("REV \(item.revision)")
                                .foregroundStyle(HerdrTheme.muted)
                        }
                        .herdrFont(.caption, monospaced: true, weight: .bold)

                        Text(item.title)
                            .herdrFont(.title2, weight: .bold)
                            .fontDesign(.rounded)
                            .foregroundStyle(HerdrTheme.text)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 7) {
                        AgentStatusBadge(status: ActiveWorkProjection.status(for: item))
                        ActiveWorkReadinessBadge(readiness: item.readiness)
                    }
                }

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
                    ActiveWorkAvatarStack(agents: ActiveWorkProjection.allAgents(for: item), size: 28, limit: 6)
                    Text("agents travel with this work")
                        .herdrFont(.caption, monospaced: true)
                        .foregroundStyle(HerdrTheme.muted)
                    Spacer()
                    if let updatedAt = item.updatedAt {
                        HStack(spacing: 4) {
                            Text("updated")
                            ActiveWorkRelativeTimestamp(value: updatedAt)
                        }
                        .herdrFont(.caption, monospaced: true)
                        .foregroundStyle(HerdrTheme.muted)
                    }
                }
            }
            .padding(HerdrTheme.cardPadding)
        }
    }

    private func actionableAttentionReason(for item: ActiveWorkItem) -> String? {
        guard item.needsAttention,
              let reason = item.attentionReason?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty else { return nil }
        let nextAction = item.nextAction?.trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.caseInsensitiveCompare(nextAction ?? "") == .orderedSame ? nil : reason
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
        .accessibilityIdentifier("active-work-stage-\(stage.key)")
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
