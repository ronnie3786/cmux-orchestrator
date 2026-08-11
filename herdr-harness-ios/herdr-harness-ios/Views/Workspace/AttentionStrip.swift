import SwiftUI

struct AttentionStrip: View {
    @Bindable var model: HerdrAppModel
    let selectPane: (HerdrPane) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Attention", systemImage: "sparkle.magnifyingglass")
                    .font(.headline.bold())
                Spacer()
                Button("See all") { model.selectedTab = .attention }
                    .font(.subheadline.bold())
            }

            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(model.attentionPanes.prefix(4)) { pane in
                        Button {
                            selectPane(pane)
                        } label: {
                            VStack(alignment: .leading, spacing: 9) {
                                AgentStatusBadge(status: pane.agentStatus, compact: true)
                                Text(pane.displayTitle)
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                Text(model.workspace(containing: pane)?.label ?? pane.workspaceID)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 188, alignment: .leading)
                            .padding(14)
                            .background(HerdrTheme.elevated.opacity(0.72), in: .rect(cornerRadius: 16))
                            .overlay {
                                RoundedRectangle(cornerRadius: 16)
                                    .strokeBorder(pane.agentStatus.color.opacity(0.25), lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}
