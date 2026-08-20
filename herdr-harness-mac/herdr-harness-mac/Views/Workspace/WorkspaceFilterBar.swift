import SwiftUI

struct WorkspaceFilterBar: View {
    @Bindable var model: HerdrAppModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(WorkspaceFilter.allCases) { filter in
                Button {
                    withAnimation(.snappy) { model.filter = filter }
                } label: {
                    HStack(spacing: 5) {
                        if model.filter == filter {
                            Image(systemName: "checkmark")
                        }
                        Text(filter.rawValue.lowercased())
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .font(.subheadline.monospaced().bold())
                .foregroundStyle(model.filter == filter ? HerdrTheme.ink : HerdrTheme.mist)
                .background(model.filter == filter ? HerdrTheme.accent : HerdrTheme.graphite)
                .overlay {
                    Rectangle().strokeBorder(HerdrTheme.surface.opacity(0.8), lineWidth: 1)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.filter == filter ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace filter")
    }
}
