import SwiftUI

struct WorkspaceFilterBar: View {
    @Bindable var model: HerdrAppModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(WorkspaceFilter.allCases) { filter in
                Button(filter.rawValue) {
                    withAnimation(.snappy) { model.filter = filter }
                }
                .font(.subheadline.bold())
                .foregroundStyle(model.filter == filter ? HerdrTheme.ink : HerdrTheme.mist)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(model.filter == filter ? HerdrTheme.accent : .white.opacity(0.07), in: Capsule())
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace filter")
    }
}
