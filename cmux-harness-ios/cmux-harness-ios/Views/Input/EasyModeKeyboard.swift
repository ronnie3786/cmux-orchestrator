import ComposableArchitecture
import SwiftUI

struct EasyModeKeyboard: View {
    @Bindable var store: StoreOf<HarnessFeature>
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(HarnessKey.inputRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row) { key in
                        easyModeButton(for: key)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func easyModeButton(for key: HarnessKey) -> some View {
        Button {
            HarnessHaptics.inputCTA()
            store.send(.sendKey(workspaceID: workspace.id, key))
        } label: {
            VStack(spacing: 4) {
                Image(systemName: key.systemImage)
                    .font(.title3.weight(.bold))

                Text(key.label)
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.white)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Send \(key.label) key")
        .accessibilityInputLabels([key.label, "\(key.label) key"])
    }
}
