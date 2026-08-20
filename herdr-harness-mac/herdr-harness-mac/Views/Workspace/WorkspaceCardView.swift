import SwiftUI

struct WorkspaceCardView: View {
    let workspace: HerdrWorkspace
    let isSelected: Bool
    let worktreeConnector: String?

    var body: some View {
        HStack(spacing: 12) {
            HerdrStatusDot(status: workspace.agentStatus)

            if let worktreeConnector {
                Text(worktreeConnector)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(HerdrTheme.muted)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(workspace.label)
                        .font(.headline.monospaced().bold())
                        .foregroundStyle(HerdrTheme.text)
                        .lineLimit(1)

                    if workspace.focused {
                        Text("active")
                            .font(.caption.monospaced().bold())
                            .foregroundStyle(HerdrTheme.accent)
                    }

                    Spacer(minLength: 4)
                    Text(workspace.agentStatus.compactTitle.lowercased())
                        .font(.caption.monospaced())
                        .foregroundStyle(workspace.agentStatus.labelColor)
                }

                Text(detail)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(HerdrTheme.mist)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: 64)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(isSelected ? HerdrTheme.accent : .clear)
                .frame(width: 2)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(HerdrTheme.surface.opacity(0.65))
                .frame(height: 1)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(workspace.label), \(workspace.agentStatus.title), \(workspace.paneCount) panes")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var detail: String {
        let branch = workspace.tokens["branch"] ?? "shell"
        return "\(branch) · \(workspace.tabCount) tab\(workspace.tabCount == 1 ? "" : "s")"
    }

    private var rowBackground: Color {
        if isSelected { return HerdrTheme.elevated }
        if workspace.focused { return HerdrTheme.graphite }
        return HerdrTheme.ink
    }
}
