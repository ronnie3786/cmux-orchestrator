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
                    .font(.subheadline.monospaced().bold())
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(1)

                if workspace.focused {
                    Text("active")
                        .font(.caption.monospaced().bold())
                        .foregroundStyle(HerdrTheme.accent)
                }

                Spacer()

                if workspace.attentionCount > 0 {
                    Text("\(workspace.attentionCount)")
                        .font(.caption2.monospaced().bold())
                        .foregroundStyle(HerdrTheme.ink)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(HerdrTheme.alert, in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 48)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar-workspace-\(workspace.id)")
        .accessibilityElement(children: .combine)
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
        .accessibilityHint("Collapses or expands this workspace's chats")
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
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .frame(minHeight: 44)
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

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                HerdrStatusDot(status: pane.agentStatus)

                Text(pane.displayTitle)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(1)

                Spacer()

                Text(pane.agentStatus.compactTitle.lowercased())
                    .font(.caption.monospaced())
                    .foregroundStyle(pane.agentStatus.labelColor)
            }
            .padding(.leading, 34)
            .padding(.trailing, 12)
            .frame(minHeight: 44)
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
        .accessibilityLabel("\(pane.displayTitle), \(pane.displayAgentName), \(pane.agentStatus.title)")
    }
}
