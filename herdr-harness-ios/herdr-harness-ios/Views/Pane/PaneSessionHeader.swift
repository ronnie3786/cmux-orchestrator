import SwiftUI

struct PaneSessionHeader: View {
    @Bindable var model: HerdrAppModel
    let pane: HerdrPane

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(pane.agentStatus.color.opacity(0.14))
                    .frame(width: 42, height: 42)
                Image(systemName: pane.agentStatus.symbol)
                    .foregroundStyle(pane.agentStatus.color)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(pane.displayAgentName)
                    .font(.subheadline.bold())
                Text(model.workspace(containing: pane)?.label ?? pane.workspaceID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
            AgentStatusBadge(status: pane.agentStatus)
        }
        .accessibilityElement(children: .combine)
    }
}
