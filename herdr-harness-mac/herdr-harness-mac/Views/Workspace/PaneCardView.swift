import SwiftUI

struct PaneCardView: View {
    let pane: HerdrPane
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 13) {
            StatusRail(status: pane.agentStatus)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(pane.displayTitle)
                        .herdrFont(.headline, weight: .bold)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    AgentStatusBadge(status: pane.agentStatus, compact: true)
                }

                HStack(spacing: 10) {
                    Label(pane.displayAgentName, systemImage: pane.agentStatus == .unknown ? "terminal" : "cpu")
                    if !pane.displayPath.isEmpty {
                        Text(pane.displayPath)
                            .fontDesign(.monospaced)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .herdrFont(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    Text(pane.id)
                    Spacer()
                    Text("rev \(pane.revision)")
                }
                .herdrFont(.caption)
                .fontDesign(.monospaced)
                .foregroundStyle(.tertiary)
            }

            Image(systemName: "chevron.right")
                .herdrFont(.caption, weight: .bold)
                .foregroundStyle(.tertiary)
        }
        .padding(15)
        .background(isSelected ? HerdrTheme.accent.opacity(0.10) : HerdrTheme.graphite.opacity(0.72))
        .background(.ultraThinMaterial)
        .clipShape(.rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(isSelected ? HerdrTheme.accent.opacity(0.50) : .white.opacity(0.08), lineWidth: 1)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(pane.displayTitle), \(pane.displayAgentName), \(pane.agentStatus.title)")
        .accessibilityHint("Opens the live terminal")
    }
}
