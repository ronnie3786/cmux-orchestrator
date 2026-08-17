import SwiftUI

struct PiModelPickerChip: View {
    let currentModel: PiModelIdentity?
    let availableModels: [PiAvailableModel]
    let isLoading: Bool
    let isSetting: Bool
    let isEnabled: Bool
    let isInteractive: Bool
    let errorMessage: String?
    let selectModel: (PiAvailableModel) -> Void
    let retry: () -> Void

    var body: some View {
        if isInteractive {
            Menu {
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
                                        systemImage: isCurrent(candidate) ? "checkmark.circle.fill" : "cpu"
                                    )
                                }
                            }
                        }
                    }
                }
            } label: {
                chipLabel
            }
            .disabled(!isEnabled)
            .accessibilityIdentifier("pi-chat-model")
            .accessibilityLabel("Model: \(currentModel?.displayName ?? "unknown")")
        } else if currentModel != nil {
            chipLabel
                .opacity(0.6)
                .accessibilityIdentifier("pi-chat-model")
                .accessibilityLabel("Model: \(currentModel?.displayName ?? "unknown")")
        }
    }

    @ViewBuilder
    private var chipLabel: some View {
        HStack(spacing: 4) {
            if isSetting {
                ProgressView()
            } else {
                Image(systemName: "cpu")
            }
            Text(currentModel?.displayName ?? "model")
                .lineLimit(1)
                .truncationMode(.middle)
            if isInteractive {
                Image(systemName: "chevron.up.down")
                    .font(.caption2)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(isInteractive ? HerdrTheme.accent : HerdrTheme.mist)
        .padding(.horizontal, 10)
        .frame(minHeight: 36)
        .background(HerdrTheme.elevated)
        .clipShape(.capsule)
        .opacity(isInteractive && !isEnabled ? 0.45 : 1)
    }

    private var modelsByProvider: [String: [PiAvailableModel]] {
        Dictionary(grouping: availableModels, by: \.provider)
    }

    private var groupedProviders: [String] {
        modelsByProvider.keys.sorted()
    }

    private func isCurrent(_ candidate: PiAvailableModel) -> Bool {
        currentModel?.provider == candidate.provider && currentModel?.id == candidate.modelID
    }
}

#Preview("Long model name stays one line") {
    HStack {
        PiModelPickerChip(
            currentModel: PiModelIdentity(
                provider: "anthropic",
                id: "claude-sonnet-4-5-20250929",
                name: "claude-sonnet-4-5-20250929"
            ),
            availableModels: [],
            isLoading: false,
            isSetting: false,
            isEnabled: true,
            isInteractive: true,
            errorMessage: nil,
            selectModel: { _ in },
            retry: {}
        )
        PiThinkingLevelChip(
            currentLevel: PiThinkingLevel.xhigh.rawValue,
            isSetting: false,
            isEnabled: true,
            isInteractive: true,
            selectLevel: { _ in }
        )
        Spacer()
    }
    .padding(.horizontal, 12)
    .frame(width: 375)
    .background(HerdrTheme.ink)
}
