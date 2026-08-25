import SwiftUI

struct AttentionPaneCard: View {
    @Bindable var model: HerdrAppModel
    let pane: HerdrPane
    let since: Date?

    var body: some View {
        GlassCard(radius: 18) {
            HStack(spacing: 13) {
                Image(systemName: pane.agentStatus.symbol)
                    .herdrFont(.title2)
                    .foregroundStyle(pane.agentStatus.color)
                    .frame(width: 42, height: 42)
                    .background(pane.agentStatus.color.opacity(0.11), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(pane.displayTitle)
                        .herdrFont(.headline, weight: .bold)
                        .foregroundStyle(.primary)
                    Text("\(model.workspace(containing: pane)?.label ?? pane.workspaceID) · \(pane.displayAgentName)")
                        .herdrFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    AgentStatusBadge(status: pane.agentStatus, compact: true)
                    if let since {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text(HerdrTimestamp.compactAge(since: since, now: context.date))
                                .herdrFont(.caption, monospaced: true, weight: .bold)
                                .foregroundStyle(pane.agentStatus.color)
                                .accessibilityLabel(
                                    HerdrTimestamp.spokenAge(since: since, now: context.date)
                                )
                        }
                    }
                }
            }
            .padding(15)
        }
    }
}
