import SwiftUI

/// The pane's identity strip: who is running, how it is doing, and where.
///
/// Dead code on iOS — the navigation bar carried the title there. The Mac
/// window has no per-pane nav bar, so this is mounted as the real header above
/// the chat/terminal area.
struct PaneSessionHeader: View {
    @Bindable var model: HerdrAppModel
    let pane: HerdrPane

    var body: some View {
        HStack(spacing: 11) {
            HerdrStatusDot(status: pane.agentStatus)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(pane.displayAgentName.lowercased())
                        .herdrFont(.subheadline, monospaced: true, weight: .bold)
                        .foregroundStyle(HerdrTheme.text)
                    Text(pane.agentStatus.compactTitle.lowercased())
                        .herdrFont(.caption, monospaced: true)
                        .foregroundStyle(pane.agentStatus.labelColor)
                }

                Text(context)
                    .herdrFont(.caption, monospaced: true)
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
            .frame(width: 30, height: 28)
            .contentShape(.rect)
            .background(HerdrTheme.graphite)
            .overlay {
                RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                    .strokeBorder(pane.focused ? HerdrTheme.accent : HerdrTheme.surface, lineWidth: 1)
            }
            .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
            .buttonStyle(.plain)
            .disabled(!model.canControl)
            .help(pane.focused ? "This pane is focused in Herdr" : "Focus this pane in Herdr")
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
