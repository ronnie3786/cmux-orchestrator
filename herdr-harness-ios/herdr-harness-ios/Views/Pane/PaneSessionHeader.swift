import SwiftUI

struct PaneSessionHeader: View {
    @Bindable var model: HerdrAppModel
    let pane: HerdrPane

    var body: some View {
        HStack(spacing: 11) {
            HerdrStatusDot(status: pane.agentStatus)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(pane.displayAgentName.lowercased())
                        .font(.subheadline.monospaced().bold())
                        .foregroundStyle(HerdrTheme.text)
                    Text(pane.agentStatus.compactTitle.lowercased())
                        .font(.caption.monospaced())
                        .foregroundStyle(pane.agentStatus.labelColor)
                }

                Text(context)
                    .font(.caption.monospaced())
                    .foregroundStyle(HerdrTheme.mist)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Button("Focus on Mac", systemImage: pane.focused ? "scope" : "macwindow") {
                Task { await model.focus(pane) }
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(pane.focused ? HerdrTheme.accent : HerdrTheme.mist)
            .frame(minWidth: 44, minHeight: 44)
            .background(HerdrTheme.graphite)
            .overlay {
                RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                    .strokeBorder(pane.focused ? HerdrTheme.accent : HerdrTheme.surface, lineWidth: 1)
            }
            .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
            .buttonStyle(.plain)
            .disabled(!model.canControl)
            .accessibilityHint(pane.focused ? "This pane is focused on your Mac" : "Focuses this pane on your Mac")
        }
        .accessibilityElement(children: .contain)
    }

    private var context: String {
        let workspace = model.workspace(containing: pane)?.label ?? pane.workspaceID
        guard !pane.displayPath.isEmpty else { return workspace }
        return "\(workspace) · \(pane.displayPath)"
    }
}
