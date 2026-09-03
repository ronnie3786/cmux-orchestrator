import SwiftUI

struct PiComposerOptionsBar: View {
    let configuration: PiPromptComposerConfiguration
    let responseAudioPlayer: ResponseAudioPlayer?
    let activateResponseAudio: ((ResponseAudioAction) -> Void)?
    let modelFavorites: ModelFavoritesStore

    var body: some View {
        HStack(spacing: 6) {
            PiModelPickerChip(
                currentModel: configuration.currentModel,
                availableModels: configuration.availableModels,
                isLoading: configuration.isLoadingModels,
                isSetting: configuration.isSettingModel,
                isEnabled: configuration.canSelectModel,
                isInteractive: configuration.supportsModelMenu,
                errorMessage: configuration.modelCatalogError,
                selectModel: { candidate in
                    Task { _ = await configuration.selectModel(candidate) }
                },
                retry: {
                    Task { await configuration.retryLoadModels() }
                },
                modelFavorites: modelFavorites
            )
            PiThinkingLevelChip(
                currentLevel: configuration.thinkingLevel,
                isSetting: configuration.isSettingThinkingLevel,
                isEnabled: configuration.canSelectThinkingLevel,
                isInteractive: configuration.supportsThinkingMenu,
                selectLevel: { level in
                    Task { _ = await configuration.selectThinkingLevel(level) }
                }
            )
            Spacer(minLength: 4)
            if let responseAudioPlayer, let activateResponseAudio {
                ResponseAudioControlsView(
                    player: responseAudioPlayer,
                    showsTitles: true,
                    activate: activateResponseAudio
                )
            }
        }
    }
}
