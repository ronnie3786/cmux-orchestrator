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
    var gitIsAvailable = false
    var selectedMode: PaneDetailMode = .terminal
    var toggleGit: () -> Void = { }
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
                    Text(pane.displayAgentName.lowercased())
                        .herdrFont(.subheadline, monospaced: true, weight: .bold)
                        .foregroundStyle(HerdrTheme.text)
                    Text(sessionStatusTitle.lowercased())
                        .herdrFont(.caption, monospaced: true)
                        .foregroundStyle(sessionStatusColor)
                        .accessibilityIdentifier("pane-session-status")
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

            LastPromptPeekButton(message: store.lastUserMessage)

            if gitIsAvailable {
                Button(
                    selectedMode == .git ? gitReturnTitle : "Git changes",
                    systemImage: PaneDetailMode.git.symbol,
                    action: toggleGit
                )
                    .labelStyle(.iconOnly)
                    .foregroundStyle(selectedMode == .git ? HerdrTheme.accent : HerdrTheme.mist)
                    .frame(width: 30, height: 28)
                    .contentShape(.rect)
                    .background(HerdrTheme.graphite)
                    .overlay {
                        RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                            .strokeBorder(
                                selectedMode == .git ? HerdrTheme.accent : HerdrTheme.surface,
                                lineWidth: 1
                            )
                    }
                    .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
                    .buttonStyle(.plain)
                    .help(selectedMode == .git ? gitReturnTitle : "Show Git changes for this pane")
                    .accessibilityIdentifier("pane-git-button")
                    .accessibilityHint(
                        selectedMode == .git
                            ? "Returns to this pane's primary view"
                            : "Shows modified files, diffs, and recent commits"
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.86)))
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
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: gitIsAvailable)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: store.compactionActivity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: store.connection)
        .accessibilityElement(children: .contain)
    }

    private var showsCompaction: Bool {
        store.connection == .connected && store.compactionActivity != nil
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

    private var gitReturnTitle: String {
        pane.supportsPiSemanticChat ? "Back to chat" : "Back to terminal"
    }
}
