import SwiftUI

struct WorkspaceHeader: View {
    @Bindable var model: HerdrAppModel
    let createWorkspace: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 13) {
                HerdrBrandMark(size: 48)
                Text("herdr")
                    .font(.largeTitle.bold())
                    .fontDesign(.rounded)

                Spacer()

                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refresh() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(model.isRefreshing)

                Button("New workspace", systemImage: "plus", action: createWorkspace)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }

            HStack {
                Text("Your agent command deck")
                    .font(.subheadline)
                    .foregroundStyle(HerdrTheme.mist)
                Spacer()
                ConnectionPill(state: model.connectionState)
            }

            if model.isDemoMode {
                Label("Demo data is active", systemImage: "sparkles")
                    .font(.footnote.bold())
                    .foregroundStyle(HerdrTheme.accent)
            }
        }
    }
}
