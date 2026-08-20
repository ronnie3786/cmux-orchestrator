import SwiftUI

/// Mac-only divergence from iOS: the navigator drops per-status hues.
///
/// On the phone the sidebar was a drawer you glanced at; on the Mac it is on
/// screen for the whole session, and five status hues repeated down every row
/// turned the column into a rainbow that fought the detail pane for attention.
/// So the sidebar spends exactly one tone on everything status-derived — dots,
/// status words, and the attention count. Differentiation comes from the
/// terminal glyph (`●` / `○` / `·`), the status word itself, and the count.
///
/// `mist` (Catppuccin Subtext0) is the tone: it is the theme's designated
/// secondary-information color, already used by the tab rows here, and reads at
/// ~7.9:1 against `ink`. `accent` was the other candidate and was rejected on
/// purpose — it means "interactive / selected" everywhere else in this column
/// (the new-workspace buttons, the selection rail, the focused-workspace
/// marker), and spending it on status would erase that meaning.
///
/// Deliberately scoped to the sidebar: `AgentStatus.color` and every other
/// surface (pane headers, status rails, the Attention deck) keep full status
/// color. Do not "fix" this by changing the shared type.
private enum SidebarTone {
    /// The single hue for every status-derived element in these rows.
    static let status = HerdrTheme.mist

    /// The attention count stays the loudest thing in a row — it is one of the
    /// two signals left after the hues went away — so it is a solid chip in the
    /// same tone rather than a second color.
    static let badgeFill = status
    static let badgeLabel = HerdrTheme.ink
}

/// Sidebar-local twin of `HerdrStatusDot`: same glyph and accessibility label,
/// single tone instead of `status.color`. The shared component is untouched.
private struct SidebarStatusDot: View {
    let status: AgentStatus

    var body: some View {
        Text(status.terminalGlyph)
            .font(.body.monospaced().bold())
            .foregroundStyle(SidebarTone.status)
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
                    .font(.caption2.bold())
                    .foregroundStyle(HerdrTheme.mist)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.snappy, value: isExpanded)

                SidebarStatusDot(status: workspace.agentStatus)

                Text(workspace.label)
                    .font(.subheadline.monospaced().bold())
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(1)

                if workspace.focused {
                    Text("active")
                        .font(.caption.monospaced().bold())
                        .foregroundStyle(HerdrTheme.accent)
                        .fixedSize()
                }

                Spacer()

                if workspace.attentionCount > 0 {
                    Text("\(workspace.attentionCount)")
                        .font(.caption2.monospaced().bold())
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

struct SidebarSectionRow: View {
    let tab: HerdrTab

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.on.square")
                .font(.caption2)
                .foregroundStyle(HerdrTheme.mist)

            Text(tab.label)
                .font(.caption.monospaced().bold())
                .foregroundStyle(HerdrTheme.mist)
                .lineLimit(1)

            Spacer()

            Text("\(tab.paneCount)")
                .font(.caption2.monospaced())
                .foregroundStyle(HerdrTheme.muted)
                .fixedSize()
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .frame(minHeight: 26)
        .contentShape(Rectangle())
        .accessibilityIdentifier("sidebar-tab-\(tab.id)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tab.label), \(tab.paneCount) panes")
    }
}

struct SidebarChatRow: View {
    let pane: HerdrPane
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                SidebarStatusDot(status: pane.agentStatus)

                Text(pane.displayTitle)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(1)

                Spacer()

                Text(pane.agentStatus.compactTitle.lowercased())
                    .font(.caption.monospaced())
                    .foregroundStyle(SidebarTone.status)
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
        .accessibilityLabel("\(pane.displayTitle), \(pane.displayAgentName), \(pane.agentStatus.title)")
    }

    private var rowBackground: Color {
        if isSelected { return HerdrTheme.elevated }
        return isHovering ? HerdrTheme.elevated.opacity(0.6) : .clear
    }
}
