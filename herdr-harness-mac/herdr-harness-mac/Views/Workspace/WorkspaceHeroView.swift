import SwiftUI

struct WorkspaceHeroView: View {
    let workspace: HerdrWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(workspace.label)
                        .herdrFont(.title, weight: .bold)
                        .fontDesign(.rounded)
                    if !workspace.displayPath.isEmpty {
                        Text(workspace.displayPath)
                            .herdrFont(.footnote)
                            .fontDesign(.monospaced)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                AgentStatusBadge(status: workspace.agentStatus)
            }

            PaneTopologyView(layout: workspace.layouts.first)
                .frame(height: 94)
                .padding(10)
                .background(.black.opacity(0.18), in: .rect(cornerRadius: 14))

            HStack(spacing: 14) {
                Label("^[\(workspace.tabCount) tab](inflect: true)", systemImage: "folder")
                Label("^[\(workspace.paneCount) pane](inflect: true)", systemImage: "rectangle.split.3x1")
                if let branch = workspace.tokens["branch"] {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .lineLimit(1)
                }
            }
            .herdrFont(.caption)
            .foregroundStyle(HerdrTheme.mist)
        }
        .padding(HerdrTheme.cardPadding)
        .background(.ultraThinMaterial)
        .background(HerdrTheme.graphite.opacity(0.62))
        .clipShape(.rect(cornerRadius: HerdrTheme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                .strokeBorder(.white.opacity(0.09), lineWidth: 1)
        }
    }
}
