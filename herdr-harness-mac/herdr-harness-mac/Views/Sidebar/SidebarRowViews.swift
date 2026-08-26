import SwiftUI

/// Mac-only divergence from iOS: the navigator reserves status hues for
/// sessions that need attention.
///
/// On the phone the sidebar was a drawer you glanced at; on the Mac it is on
/// screen for the whole session, and five status hues repeated down every row
/// turned the column into a rainbow that fought the detail pane for attention.
/// Calm states spend exactly one tone on status-derived dots and words, while
/// blocked and completed sessions light up in their real status color. That
/// keeps the column quiet while still making the items that need attention
/// easy to scan without opening the Attention deck. Differentiation for calm
/// states comes from the terminal glyph (`●` / `○` / `·`) and status word.
///
/// `mist` (Catppuccin Subtext0) is the tone: it is the theme's designated
/// secondary-information color, already used by the tab rows here, and reads at
/// ~7.9:1 against `ink`. `accent` was the other candidate and was rejected on
/// purpose — it means "interactive / selected" everywhere else in this column
/// (the new-workspace buttons, the selection rail, the focused-workspace
/// marker), and spending it on status would erase that meaning.
///
/// Deliberately scoped to the sidebar: this selective override belongs here,
/// not on the shared `AgentStatus` type.
enum SidebarTone {
    /// The single hue for calm status-derived elements in these rows.
    static let status = HerdrTheme.mist

    static let badgeFill = HerdrTheme.alert
    static let badgeLabel = HerdrTheme.ink

    static func statusColor(for status: AgentStatus) -> Color {
        status.needsAttention ? status.color : Self.status
    }
}

/// Sidebar-local twin of `HerdrStatusDot`: same glyph and accessibility label,
/// calm states use one tone while attention states use `status.color`.
private struct SidebarStatusDot: View {
    let status: AgentStatus

    var body: some View {
        Text(status.terminalGlyph)
            .herdrFont(.body, monospaced: true, weight: .bold)
            .foregroundStyle(SidebarTone.statusColor(for: status))
            .accessibilityLabel(status.title)
    }
}

struct SidebarProjectRow: View {
    let workspace: HerdrWorkspace
    let isExpanded: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .herdrFont(.caption2, weight: .bold)
                    .foregroundStyle(HerdrTheme.mist)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.snappy, value: isExpanded)

                SidebarStatusDot(status: workspace.agentStatus)

                Text(workspace.label)
                    .herdrFont(.subheadline, monospaced: true, weight: .bold)
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(1)

                if workspace.focused {
                    Text("active")
                        .herdrFont(.caption, monospaced: true, weight: .bold)
                        .foregroundStyle(HerdrTheme.accent)
                        .fixedSize()
                }

                Spacer()

                if workspace.attentionCount > 0 {
                    Text("\(workspace.attentionCount)")
                        .herdrFont(.caption2, monospaced: true, weight: .bold)
                        .foregroundStyle(SidebarTone.badgeLabel)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(SidebarTone.badgeFill, in: Capsule())
                        .accessibilityLabel("\(workspace.attentionCount) needing attention")
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .contentShape(Rectangle())
            .background(isHovering ? HerdrTheme.elevated.opacity(0.6) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(tooltip)
        .accessibilityIdentifier("sidebar-workspace-\(workspace.id)")
        .accessibilityElement(children: .combine)
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
        .accessibilityHint("Collapses or expands this workspace's chats")
    }

    /// The chat rows below spell their status out in words; a workspace row only
    /// ever carried it as a hue. With one tone the hover tooltip is where that
    /// detail goes — the mac-native place for it, and no extra chrome in the row.
    private var tooltip: String {
        let location = workspace.displayPath.isEmpty ? workspace.label : workspace.displayPath
        return "\(location) — \(workspace.agentStatus.title)"
    }
}

struct SidebarMachineRow: View {
    let machine: HerdrMachine
    let state: ConnectionState
    let paneCount: Int
    let isExpanded: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .herdrFont(.caption2, weight: .bold)
                    .foregroundStyle(HerdrTheme.mist)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.snappy, value: isExpanded)

                Image(systemName: "desktopcomputer")
                    .herdrFont(.caption, weight: .semibold)
                    .foregroundStyle(SidebarTone.status.opacity(statusOpacity))

                Text(machine.name.uppercased())
                    .herdrFont(.subheadline, monospaced: true, weight: .bold)
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(1)

                Spacer()

                Text("\(paneCount) panes")
                    .herdrFont(.caption, monospaced: true)
                    .foregroundStyle(HerdrTheme.muted)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .contentShape(Rectangle())
            .background(isHovering ? HerdrTheme.elevated : HerdrTheme.graphite)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(SidebarTone.status.opacity(statusOpacity))
                    .frame(width: 3)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("\(machine.name) — \(machine.urlString) — \(state.title)")
        .accessibilityIdentifier("sidebar-machine-\(machine.id)")
        .accessibilityElement(children: .combine)
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
        .accessibilityHint("Collapses or expands this machine's chats")
    }

    private var statusOpacity: Double {
        switch state {
        case .live, .demo: 1
        case .connecting: 0.7
        case .disconnected, .failed: 0.45
        }
    }
}

struct SidebarSectionRow: View {
    let tab: HerdrTab
    let isExpanded: Bool
    var attentionStatus: AgentStatus?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: attentionStatus != nil ? "folder.fill" : (isExpanded ? "folder" : "folder.fill"))
                    .herdrFont(.caption2)
                    .foregroundStyle(folderColor)

                Text(tab.label)
                    .herdrFont(.caption, monospaced: true, weight: .bold)
                    .foregroundStyle(attentionStatus != nil ? HerdrTheme.text : HerdrTheme.mist)
                    .lineLimit(1)

                Spacer()

                Text("\(tab.paneCount)")
                    .herdrFont(.caption2, monospaced: true)
                    .foregroundStyle(HerdrTheme.muted)
                    .fixedSize()
            }
            .padding(.leading, 18)
            .padding(.trailing, 12)
            .frame(minHeight: 26)
            .contentShape(Rectangle())
            .background(isHovering ? HerdrTheme.elevated.opacity(0.6) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier("sidebar-tab-\(tab.id)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
        .accessibilityHint("Collapses or expands this tab's chats")
    }

    private var folderColor: Color {
        attentionStatus?.color ?? HerdrTheme.mist
    }

    private var accessibilityLabel: String {
        let attention = attentionStatus.map { ", \($0.title)" } ?? ""
        return "\(tab.label), \(tab.paneCount) panes\(attention)"
    }
}

struct SidebarChatRow: View {
    let pane: HerdrPane
    let isSelected: Bool
    var isStarred: Bool = false
    var statusSince: Date?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                SidebarStatusDot(status: pane.agentStatus)

                Text(pane.displayTitle)
                    .herdrFont(.subheadline, monospaced: true)
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(1)

                Spacer()

                if isStarred {
                    Image(systemName: "star.fill")
                        .herdrFont(.caption2, monospaced: true)
                        .foregroundStyle(SidebarTone.status)
                }

                SidebarStatusAgeLabel(status: pane.agentStatus, since: statusSince)
                    .herdrFont(.caption, monospaced: true)
                    .foregroundStyle(SidebarTone.statusColor(for: pane.agentStatus))
                    .fixedSize()
            }
            .padding(.leading, 34)
            .padding(.trailing, 12)
            .frame(minHeight: 26)
            .contentShape(Rectangle())
            .background(rowBackground)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isSelected ? HerdrTheme.accent : .clear)
                    .frame(width: 2)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(pane.displayTitle)
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

    private var rowBackground: Color {
        if isSelected { return HerdrTheme.elevated }
        return isHovering ? HerdrTheme.elevated.opacity(0.6) : .clear
    }
}
