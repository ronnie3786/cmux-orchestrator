import SwiftUI

struct WorkspaceHeader: View {
    @Bindable var model: HerdrAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                HerdrBrandMark(size: 42)

                VStack(alignment: .leading, spacing: 1) {
                    Text("herdr")
                        .font(.title.bold())
                    Text("switch")
                        .font(.caption.monospaced())
                        .foregroundStyle(HerdrTheme.mist)
                }

                Spacer()

                Button("Open navigator", systemImage: "sidebar.leading") {
                    model.isSidebarPresented = true
                }
                .labelStyle(.iconOnly)
                .font(.headline.bold())
                .foregroundStyle(HerdrTheme.accent)
                .frame(width: 48, height: 48)
                .background(HerdrTheme.elevated)
                .overlay {
                    RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                        .strokeBorder(HerdrTheme.surface, lineWidth: 1)
                }
                .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar-toggle")

                HerdPulseButton()

                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refresh() }
                }
                .labelStyle(.iconOnly)
                .font(.headline.bold())
                .foregroundStyle(HerdrTheme.accent)
                .frame(width: 48, height: 48)
                .background(HerdrTheme.elevated)
                .overlay {
                    RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                        .strokeBorder(HerdrTheme.surface, lineWidth: 1)
                }
                .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
                .buttonStyle(.plain)
                .disabled(model.isRefreshing)

            }

            HStack {
                Text("choose a workspace")
                    .font(.subheadline.monospaced())
                    .foregroundStyle(HerdrTheme.mist)
                Spacer()
                ConnectionPill(state: model.connectionState)
            }

            if model.isDemoMode {
                Label("Demo data is active", systemImage: "sparkles")
                    .font(.footnote.monospaced().bold())
                    .foregroundStyle(HerdrTheme.accent)
            }
        }
    }
}
