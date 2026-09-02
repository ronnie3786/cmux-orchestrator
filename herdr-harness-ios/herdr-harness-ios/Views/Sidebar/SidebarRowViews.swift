import SwiftUI

struct SidebarProjectRow: View {
    let workspace: HerdrWorkspace
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption2.bold())
                    .foregroundStyle(HerdrTheme.mist)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.snappy, value: isExpanded)

                HerdrStatusDot(status: workspace.agentStatus)

                Text(workspace.label)
                    .font(.subheadline.bold())
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(1)

                if workspace.focused {
                    Text("active")
                        .font(.caption.bold())
                        .foregroundStyle(HerdrTheme.accent)
                        .fixedSize()
                }

                Spacer()

                if workspace.attentionCount > 0 {
                    Text("\(workspace.attentionCount)")
                        .font(.caption2.bold().monospacedDigit())
                        .foregroundStyle(HerdrTheme.ink)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(HerdrTheme.alert, in: Capsule())
                        .accessibilityLabel("\(workspace.attentionCount) needing attention")
                }
            }
            .padding(.leading, SidebarMetrics.workspaceRowLeadingPadding)
            .padding(.trailing, SidebarMetrics.rowTrailingPadding)
            .frame(minHeight: SidebarMetrics.projectRowHeight)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar-workspace-\(workspace.id)")
        .accessibilityElement(children: .combine)
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
        .accessibilityHint("Collapses or expands this workspace's chats")
    }
}

struct SidebarMachineRow: View {
    let machine: HerdrMachine
    let state: ConnectionState
    let paneCount: Int
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption2.bold())
                    .foregroundStyle(HerdrTheme.mist)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.snappy, value: isExpanded)

                Circle()
                    .fill(state.color)
                    .frame(width: 8, height: 8)

                Text(machine.name.lowercased())
                    .font(.subheadline.bold())
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(1)

                Spacer()

                Text("\(paneCount) panes")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(HerdrTheme.muted)
                    .fixedSize()
            }
            .padding(.leading, SidebarMetrics.workspaceRowLeadingPadding)
            .padding(.trailing, SidebarMetrics.rowTrailingPadding)
            .frame(minHeight: SidebarMetrics.machineRowHeight)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar-machine-\(machine.id)")
        .accessibilityElement(children: .combine)
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
        .accessibilityHint("Collapses or expands this machine's chats")
    }
}

struct SidebarSectionRow: View {
    let tab: HerdrTab
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "folder" : "folder.fill")
                    .font(.caption2)
                    .foregroundStyle(HerdrTheme.mist)

                Text(tab.label)
                    .font(.caption.bold())
                    .foregroundStyle(HerdrTheme.mist)
                    .lineLimit(1)

                Spacer()

                Text("\(tab.paneCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(HerdrTheme.muted)
                    .fixedSize()
            }
            .padding(.leading, SidebarMetrics.tabRowLeadingPadding)
            .padding(.trailing, SidebarMetrics.rowTrailingPadding)
            .frame(minHeight: SidebarMetrics.tabRowHeight)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar-tab-\(tab.id)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tab.label), \(tab.paneCount) panes")
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
        .accessibilityHint("Collapses or expands this tab's chats")
    }
}

struct SidebarChatRow: View {
    let pane: HerdrPane
    let isSelected: Bool
    var isStarred: Bool = false
    var statusSince: Date?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                HerdrStatusDot(status: pane.agentStatus)

                Text(pane.displayTitle)
                    .font(.subheadline)
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(1)

                Spacer()

                if isStarred {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(HerdrTheme.muted)
                }

                SidebarStatusAgeLabel(status: pane.agentStatus, since: statusSince)
                    .font(.caption.monospaced())
                    .foregroundStyle(pane.agentStatus.labelColor)
                    .fixedSize()
            }
            .padding(.leading, SidebarMetrics.chatRowLeadingPadding)
            .padding(.trailing, SidebarMetrics.rowTrailingPadding)
            .frame(minHeight: SidebarMetrics.chatRowHeight)
            .background(isSelected ? HerdrTheme.elevated : .clear)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isSelected ? HerdrTheme.accent : .clear)
                    .frame(width: 2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar-pane-\(pane.id)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard let statusSince else {
            return "\(pane.displayTitle), \(pane.displayAgentName), \(pane.agentStatus.title)"
        }
        return "\(pane.displayTitle), \(pane.displayAgentName), \(pane.agentStatus.title), \(HerdrTimestamp.spokenAge(since: statusSince))"
    }
}
