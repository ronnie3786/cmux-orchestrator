import SwiftUI

struct HerdrHudAttentionStripView: View {
    @Bindable var model: HerdrAppModel
    let openPaneInMainWindow: (String) -> Void
    let collapse: () -> Void

    var body: some View {
        let panes = HerdrHudNotificationFilter.panes(model.attentionPanes)
        if !panes.isEmpty {
            let filteredAlerts = HerdrHudNotificationFilter.alerts(
                model.alerts,
                panes: model.workspaces.flatMap(\.panes)
            )
            let attention = HerdPulseAttentionRows.attentionRows(
                panes: panes,
                alerts: filteredAlerts,
                revealTitles: model.showSessionTitles,
                limit: 3
            )
            Divider().overlay { HerdrTheme.surface }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(attention.rows) { row in
                    Button {
                        openPaneInMainWindow(row.id)
                        collapse()
                    } label: {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(row.status.color)
                                .frame(width: 6, height: 6)
                            Text(row.title)
                                .herdrFont(.caption, monospaced: true)
                                .foregroundStyle(HerdrTheme.mist)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, HerdrTheme.cardPadding)
                        .frame(minHeight: HerdrTheme.minHitTarget)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(row.title), \(row.subtitle)")
                    .accessibilityIdentifier("hud-attention-row-\(row.id)")
                }
            }
            .padding(.vertical, 5)
        }
    }
}
