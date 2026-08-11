import SwiftUI

struct WorkspaceCardView: View {
    let workspace: HerdrWorkspace

    var body: some View {
        GlassCard {
            HStack(spacing: 14) {
                StatusRail(status: workspace.agentStatus)

                VStack(alignment: .leading, spacing: 13) {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(workspace.label)
                                .font(.headline.bold())
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if !workspace.displayPath.isEmpty {
                                Text(workspace.displayPath)
                                    .font(.caption)
                                    .fontDesign(.monospaced)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }

                        Spacer(minLength: 4)
                        AgentStatusBadge(status: workspace.agentStatus, compact: true)
                    }

                    HStack(spacing: 12) {
                        PaneTopologyView(layout: workspace.layouts.first)
                            .frame(width: 86, height: 48)

                        VStack(alignment: .leading, spacing: 5) {
                            Label("^[\(workspace.paneCount) pane](inflect: true)", systemImage: "rectangle.split.3x1")
                            Label("^[\(workspace.tabCount) tab](inflect: true)", systemImage: "square.on.square")
                        }
                        .font(.caption)
                        .foregroundStyle(HerdrTheme.mist)

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.footnote.bold())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(HerdrTheme.cardPadding)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(workspace.label), \(workspace.agentStatus.title), \(workspace.paneCount) panes")
    }
}
