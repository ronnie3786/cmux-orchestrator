import SwiftUI

struct HerdrHudModelChip: View {
    let currentSelectionID: String?
    let availableModels: [PiAvailableModel]
    let defaultModel: PiModelIdentity?
    let isLoading: Bool
    let errorMessage: String?
    let selectModel: (PiAvailableModel?) -> Void
    let retry: () -> Void

    var body: some View {
        Menu {
            Button {
                selectModel(nil)
            } label: {
                Label(defaultMenuTitle, systemImage: currentSelectionID == nil ? "checkmark.circle.fill" : "cpu")
            }

            if isLoading {
                Text("Loading models…").disabled(true)
            } else if let errorMessage {
                Text(errorMessage).disabled(true)
                Button("Retry", action: retry)
            } else if availableModels.isEmpty {
                Text("No models available").disabled(true)
            } else {
                ForEach(groupedProviders, id: \.self) { provider in
                    Section(provider) {
                        ForEach(modelsByProvider[provider] ?? []) { candidate in
                            Button {
                                selectModel(candidate)
                            } label: {
                                Label(
                                    candidate.displayName,
                                    systemImage: candidate.id == currentSelectionID ? "checkmark.circle.fill" : "cpu"
                                )
                            }
                        }
                    }
                }
            }
        } label: {
            chipLabel
        }
        .piChipMenu()
        .accessibilityIdentifier("hud-model")
        .accessibilityLabel("Model: \(selectedDisplayName)")
    }

    private var defaultMenuTitle: String {
        guard let defaultModel else { return "Default" }
        return "Default: \(defaultModel.displayName)"
    }

    private var selectedDisplayName: String {
        guard let currentSelectionID else { return "Default" }
        return availableModels.first(where: { $0.id == currentSelectionID })?.displayName ?? currentSelectionID
    }

    private var chipLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: isLoading ? "hourglass" : "cpu")
            Text(selectedDisplayName)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.up.chevron.down")
                .herdrFont(.caption2)
        }
        .herdrFont(.caption, weight: .semibold)
        .foregroundStyle(HerdrTheme.accent)
        .padding(.horizontal, 10)
        .frame(minHeight: 36)
        .background(HerdrTheme.elevated)
        .clipShape(.capsule)
    }

    private var modelsByProvider: [String: [PiAvailableModel]] {
        Dictionary(grouping: availableModels, by: \.provider)
    }

    private var groupedProviders: [String] {
        modelsByProvider.keys.sorted()
    }
}
