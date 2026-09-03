import SwiftUI

struct PiChatView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var store: PiConversationStore
    let paneID: String
    let interactionResponseAvailable: Bool
    let composerPane: HerdrPane
    let workspace: HerdrWorkspace
    @Binding var draft: String
    @Binding var attachments: [TerminalAttachment]
    let focusRequest: Int
    let interactionResponder: PiInteractionResponder
    let modelFavorites: ModelFavoritesStore
    @State private var hapticPulse = HerdrHapticPulse()
    @State private var responseAudioPlayer = ResponseAudioPlayer()

    var body: some View {
        VStack(spacing: 0) {
            PiConnectionBanner(
                connection: store.connection,
                message: store.lastError,
                transport: store.transport
            )

            PiContextMeterView(usage: store.contextUsage, cost: store.sessionCost)

            PiChatTimelineView(
                store: store,
                isConnected: store.canSendCommands
                    && interactionResponseAvailable
            ) { interaction, response in
                await interactionResponder.respond(
                    to: interaction,
                    response: response,
                    store: store,
                    model: model,
                    pane: composerPane
                )
            }
            .id(paneID)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let notice = store.commandNotice {
                Text(notice)
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.signal)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .transition(.opacity)
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(2.5))
                        store.clearCommandNotice()
                    }
            }

            PromptComposerView(
                model: model,
                pane: composerPane,
                workspace: workspace,
                draft: $draft,
                attachments: $attachments,
                focusRequest: focusRequest,
                piConfiguration: composerConfiguration,
                responseAudioPlayer: responseAudioPlayer,
                activateResponseAudio: activateResponseAudio,
                modelFavorites: modelFavorites
            )
            .equatable()
            .id(paneID)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(HerdrTheme.surface.opacity(0.55))
                    .frame(height: 1)
            }
        }
        .onChange(of: store.phase) { oldPhase, newPhase in
            if oldPhase == .working, newPhase == .idle {
                hapticPulse.fire(.completed)
            } else if newPhase == .failed {
                hapticPulse.fire(.failed)
            }
            responseAudioPlayer.responseDidChange(
                hasResponse: newPhase != .working
                    && store.latestCompletedAssistantResponse != nil
            )
        }
        .onChange(of: store.latestCompletedAssistantResponse) { _, response in
            responseAudioPlayer.responseDidChange(
                hasResponse: store.phase != .working && response != nil
            )
        }
        .task(id: paneID) {
            responseAudioPlayer.responseDidChange(
                hasResponse: store.phase != .working
                    && store.latestCompletedAssistantResponse != nil
            )
            await responseAudioPlayer.loadCapabilities {
                try await model.fetchResponseAudioCapabilities(for: composerPane)
            }
        }
        .onDisappear {
            responseAudioPlayer.stop()
        }
        .herdrHaptic(trigger: hapticPulse)
        .accessibilityIdentifier("pi-chat-view")
    }

    private var composerConfiguration: PiPromptComposerConfiguration {
        PiPromptComposerConfiguration(
            capabilities: composerPane.piSemantic?.capabilities ?? .unavailable,
            phase: store.phase,
            compactionActivity: store.compactionActivity,
            isConnected: store.canSendCommands,
            isSubmitting: store.isSubmitting,
            isAborting: store.isAborting,
            currentModel: store.currentModel,
            availableModels: store.availableModels,
            isLoadingModels: store.isLoadingModels,
            isSettingModel: store.isSettingModel,
            modelCatalogError: store.modelCatalogError,
            isModelSwitchingUnsupported: store.isModelSwitchingUnsupported,
            submit: { text, disposition in
                await store.submit(
                    text: text,
                    disposition: disposition,
                    model: model,
                    pane: composerPane
                )
            },
            abort: {
                await store.abort(model: model, pane: composerPane)
            },
            selectModel: { candidate in
                let succeeded = await store.setModel(candidate, model: model, pane: composerPane)
                if succeeded { hapticPulse.fire(.selection) }
                return succeeded
            },
            retryLoadModels: {
                await store.retryLoadModels(model: model, pane: composerPane)
            },
            thinkingLevel: store.thinkingLevel,
            isSettingThinkingLevel: store.isSettingThinkingLevel,
            selectThinkingLevel: { level in
                let succeeded = await store.setThinkingLevel(level, model: model, pane: composerPane)
                if succeeded { hapticPulse.fire(.selection) }
                return succeeded
            }
        )
    }

    private func activateResponseAudio(_ action: ResponseAudioAction) {
        guard let response = store.latestCompletedAssistantResponse else { return }
        responseAudioPlayer.activate(
            action,
            text: response,
            prepare: { action, text in
                try await model.prepareResponseAudio(
                    action: action,
                    text: text,
                    for: composerPane
                )
            },
            synthesize: { text in
                try await model.synthesizeResponseAudio(text: text, for: composerPane)
            },
            failure: { message in
                model.errorMessage = message
            }
        )
    }
}

extension PiChatView: Equatable {
    static func == (lhs: PiChatView, rhs: PiChatView) -> Bool {
        lhs.model === rhs.model
            && lhs.store === rhs.store
            && lhs.paneID == rhs.paneID
            && lhs.interactionResponseAvailable == rhs.interactionResponseAvailable
            && lhs.composerPane.isEqualIgnoringRevision(to: rhs.composerPane)
            && lhs.workspace.isEqualIgnoringPaneRevisions(to: rhs.workspace)
            && lhs.draft == rhs.draft
            && lhs.attachments == rhs.attachments
            && lhs.focusRequest == rhs.focusRequest
            && lhs.interactionResponder === rhs.interactionResponder
            && lhs.modelFavorites === rhs.modelFavorites
    }
}
