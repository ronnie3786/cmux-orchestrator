import SwiftUI

struct AlertCardView: View {
    let alert: HerdrAlert
    let pane: HerdrPane?

    var body: some View {
        GlassCard(radius: 18) {
            HStack(alignment: .top, spacing: 13) {
                StatusRail(status: alert.status)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        AgentStatusBadge(status: alert.status, compact: true)
                        Spacer()
                        if !alert.isRead {
                            Text("NEW")
                                .herdrFont(.caption, weight: .bold)
                                .foregroundStyle(HerdrTheme.ink)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(HerdrTheme.accent, in: Capsule())
                        }
                    }
                    Text(alert.title)
                        .herdrFont(.headline, weight: .bold)
                        .foregroundStyle(.primary)
                    if !alert.message.isEmpty {
                        Text(alert.message)
                            .herdrFont(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Label(agentLabel, systemImage: pane == nil ? "archivebox" : "cpu")
                        .herdrFont(.caption)
                        .foregroundStyle(.tertiary)
                }

                if pane != nil {
                    Image(systemName: "chevron.right")
                        .herdrFont(.caption, weight: .bold)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
            }
            .padding(15)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var agentLabel: String {
        pane?.displayAgentName ?? "Closed pane · \(alert.paneID)"
    }

    private var accessibilitySummary: String {
        [alert.title, alert.status.title, alert.message, agentLabel]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}
