import SwiftUI

struct PiChatView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var store: PiConversationStore
    let pane: HerdrPane
    let workspace: HerdrWorkspace
    @Binding var draft: String
    @Binding var attachments: [TerminalAttachment]
    let focusRequest: Int
    @State private var dismissFocusRequest = 0
    @State private var hapticPulse = HerdrHapticPulse()

    var body: some View {
        VStack(spacing: 0) {
            PiConnectionBanner(connection: store.connection, message: store.lastError)

            PiContextMeterView(usage: store.contextUsage)

            PiChatTimelineView(
                store: store,
                isConnected: store.canSendCommands
                    && (pane.piSemantic?.capabilities.interactionResponse ?? false),
                onKeyboardDismissRequested: dismissKeyboard
            ) { interaction, response in
                await store.respond(to: interaction, response: response, model: model, pane: pane)
            }
            .id(pane.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let notice = store.commandNotice {
                Text(notice)
                    .font(.caption)
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
                pane: pane,
                workspace: workspace,
                draft: $draft,
                attachments: $attachments,
                focusRequest: focusRequest,
                dismissFocusRequest: dismissFocusRequest,
                piConfiguration: composerConfiguration
            )
            .id(pane.id)
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
        }
        .herdrHaptic(trigger: hapticPulse)
        .accessibilityIdentifier("pi-chat-view")
    }

    private var composerConfiguration: PiPromptComposerConfiguration {
        PiPromptComposerConfiguration(
            capabilities: pane.piSemantic?.capabilities ?? .unavailable,
            phase: store.phase,
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
                    pane: pane
                )
            },
            abort: {
                await store.abort(model: model, pane: pane)
            },
            selectModel: { candidate in
                let succeeded = await store.setModel(candidate, model: model, pane: pane)
                if succeeded { hapticPulse.fire(.selection) }
                return succeeded
            },
            retryLoadModels: {
                await store.retryLoadModels(model: model, pane: pane)
            },
            thinkingLevel: store.thinkingLevel,
            isSettingThinkingLevel: store.isSettingThinkingLevel,
            selectThinkingLevel: { level in
                let succeeded = await store.setThinkingLevel(level, model: model, pane: pane)
                if succeeded { hapticPulse.fire(.selection) }
                return succeeded
            }
        )
    }

    private func dismissKeyboard() {
        dismissFocusRequest &+= 1
    }
}
