import SwiftUI

struct AttentionPaneCard: View {
    @Bindable var model: HerdrAppModel
    let pane: HerdrPane

    var body: some View {
        GlassCard(radius: 18) {
            HStack(spacing: 13) {
                Image(systemName: pane.agentStatus.symbol)
                    .font(.title2)
                    .foregroundStyle(pane.agentStatus.color)
                    .frame(width: 42, height: 42)
                    .background(pane.agentStatus.color.opacity(0.11), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(pane.displayTitle)
                        .font(.headline.bold())
                        .foregroundStyle(.primary)
                    Text("\(model.workspace(containing: pane)?.label ?? pane.workspaceID) · \(pane.displayAgentName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
                AgentStatusBadge(status: pane.agentStatus, compact: true)
            }
            .padding(15)
        }
    }
}
