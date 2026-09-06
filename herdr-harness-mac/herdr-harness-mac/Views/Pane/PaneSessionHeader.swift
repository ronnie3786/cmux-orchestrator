import SwiftUI

/// The pane's identity strip: who is running, how it is doing, and where.
///
/// Dead code on iOS — the navigation bar carried the title there. The Mac
/// window has no per-pane nav bar, so this is mounted as the real header above
/// the chat/terminal area.
struct PaneSessionHeader: View {
    @Bindable var model: HerdrAppModel
    let pane: HerdrPane
    let store: PiConversationStore
    var showsPiSessionSummary = false
    var summarizePiSession: () -> Void = { }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 11) {
            if showsCompaction {
                ProgressView()
                    .controlSize(.small)
                    .tint(HerdrTheme.working)
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
            } else {
                HerdrStatusDot(status: pane.agentStatus)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    // The chat's own name leads: the agent and status that used
                    // to start this line say what kind of session it is, not
                    // which one you are looking at.
                    Text(pane.displayTitle)
                        .herdrFont(.subheadline, weight: .bold)
                        .foregroundStyle(HerdrTheme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("pane-session-title")

                    if showsAgentName {
                        Text(pane.displayAgentName.lowercased())
                            .herdrFont(.caption, monospaced: true, weight: .bold)
                            .foregroundStyle(HerdrTheme.mist)
                            .fixedSize()
                    }

                    Text(sessionStatusTitle.lowercased())
                        .herdrFont(.caption, monospaced: true)
                        .foregroundStyle(sessionStatusColor)
                        .fixedSize()
                        .accessibilityIdentifier("pane-session-status")

                    if let lastActivityAt = pane.lastActivityAt {
                        // Re-renders on its own so an open chat's staleness does
                        // not freeze at whatever it read when the view mounted.
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text(Self.stalenessLabel(since: lastActivityAt, now: context.date))
                                .herdrFont(.caption, monospaced: true)
                                .foregroundStyle(Self.stalenessColor(since: lastActivityAt, now: context.date))
                                .accessibilityLabel(
                                    "Last activity \(HerdrTimestamp.spokenAge(since: lastActivityAt, now: context.date))"
                                )
                        }
                        .fixedSize()
                        .help("Last message in this chat")
                        .accessibilityIdentifier("pane-session-last-activity")
                    }
                }

                HStack(spacing: 3) {
                    Text(locationName)
                        .herdrFont(.caption, monospaced: true)
                        .foregroundStyle(HerdrTheme.mist)
                        .lineLimit(1)

                    if !pane.displayPath.isEmpty {
                        Text("·")
                            .herdrFont(.caption, monospaced: true)
                            .foregroundStyle(HerdrTheme.mist)
                            .accessibilityHidden(true)

                        PanePathButton(
                            path: pane.displayPath,
                            reportFailure: reportPathOpenFailure
                        )
                        .layoutPriority(1)
                    }
                }
            }

            Spacer(minLength: 8)

            PromptHistoryButton(
                history: model.promptHistory,
                paneID: pane.id,
                reuse: { model.setComposerDraft($0, for: pane.id) }
            )

            if showsPiSessionSummary {
                Button("Summarize", systemImage: "list.bullet.clipboard", action: summarizePiSession)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!model.canControl(machineID: pane.machineID))
                    .help("Summarize this Pi session and where you left off")
                    .accessibilityIdentifier("pane-summarize-pi-session")
                    .accessibilityHint("Opens a short summary generated in a separate headless Pi session")
            }

            Button("Focus on Mac", systemImage: pane.focused ? "scope" : "macwindow") {
                Task { await model.focus(pane) }
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(pane.focused ? HerdrTheme.accent : HerdrTheme.mist)
            .frame(width: 30, height: 28)
            .contentShape(.rect)
            .background(HerdrTheme.graphite)
            .overlay {
                RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                    .strokeBorder(pane.focused ? HerdrTheme.accent : HerdrTheme.surface, lineWidth: 1)
            }
            .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
            .buttonStyle(.plain)
            .disabled(!model.canControl(machineID: pane.machineID))
            .help(pane.focused ? "This pane is focused in cmux" : "Focus this pane in cmux")
            .accessibilityHint(pane.focused ? "This pane is focused on your Mac" : "Focuses this pane on your Mac")
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: store.compactionActivity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: store.connection)
        .accessibilityElement(children: .contain)
    }

    /// How stale the chat is, as a clock time for today and a date beyond it.
    ///
    /// A bare age ("3d") answers "how long" but not "since when", and the point
    /// of this label is deciding whether a chat is worth returning to. Today's
    /// chats get a wall-clock time, yesterday's get named, and anything older
    /// gets a date — each the shortest form that is still unambiguous.
    static func stalenessLabel(since date: Date, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(.dateTime.hour().minute())
        }
        if calendar.isDateInYesterday(date) {
            return "yesterday \(date.formatted(.dateTime.hour().minute()))"
        }
        if let sixDaysAgo = calendar.date(byAdding: .day, value: -6, to: now), date >= sixDaysAgo {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// Goes quiet for a fresh chat and warms up once it has been sitting for a
    /// day, so staleness is scannable without reading the label.
    static func stalenessColor(since date: Date, now: Date = Date()) -> Color {
        now.timeIntervalSince(date) >= 86_400 ? HerdrTheme.muted : HerdrTheme.mist
    }

    private var showsCompaction: Bool {
        store.connection == .connected && store.compactionActivity != nil
    }

    /// `displayTitle` falls back to the agent name when a pane has no label of
    /// its own, and "pi pi idle" reads like a rendering bug. Drop the duplicate.
    private var showsAgentName: Bool {
        pane.displayTitle.caseInsensitiveCompare(pane.displayAgentName) != .orderedSame
    }

    private var sessionStatusTitle: String {
        switch store.connection {
        case .bridgeOffline:
            "Offline"
        case .reconnecting:
            "Reconnecting"
        case .unavailable:
            "Unavailable"
        case .loading, .connected:
            showsCompaction ? "Compacting" : pane.agentStatus.compactTitle
        }
    }

    private var sessionStatusColor: Color {
        switch store.connection {
        case .bridgeOffline, .reconnecting, .unavailable:
            HerdrTheme.warning
        case .loading, .connected:
            showsCompaction ? HerdrTheme.working : pane.agentStatus.labelColor
        }
    }

    private var locationName: String {
        guard let workspace = model.workspace(containing: pane) else { return pane.workspaceID }
        guard let tab = workspace.tabs.first(where: { $0.id == pane.scopedTabID }) else {
            return workspace.label
        }
        return "\(workspace.label) · \(tab.label)"
    }

    private func reportPathOpenFailure(_ message: String) {
        model.toastMessage = message
    }

}
