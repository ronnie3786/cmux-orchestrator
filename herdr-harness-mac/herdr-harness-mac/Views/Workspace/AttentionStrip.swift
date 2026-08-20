import SwiftUI

struct AttentionStrip: View {
    @Bindable var model: HerdrAppModel
    let selectPane: (HerdrPane) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HerdrSectionLabel(title: "attention", detail: "\(model.attentionPanes.count)")
                Spacer()
                Button("open queue") { model.selectedTab = .attention }
                    .font(.subheadline.monospaced().bold())
            }

            ForEach(model.attentionPanes.prefix(2)) { pane in
                Button {
                    selectPane(pane)
                } label: {
                    HStack(spacing: 10) {
                        HerdrStatusDot(status: pane.agentStatus)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(pane.displayTitle)
                                .font(.subheadline.monospaced().bold())
                                .foregroundStyle(HerdrTheme.text)
                                .lineLimit(1)
                            Text(model.workspace(containing: pane)?.label ?? pane.workspaceID)
                                .font(.caption.monospaced())
                                .foregroundStyle(HerdrTheme.mist)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(pane.agentStatus.compactTitle.lowercased())
                            .font(.caption.monospaced())
                            .foregroundStyle(pane.agentStatus.color)
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 54)
                    .background(HerdrTheme.graphite)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(HerdrTheme.surface.opacity(0.65)).frame(height: 1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
