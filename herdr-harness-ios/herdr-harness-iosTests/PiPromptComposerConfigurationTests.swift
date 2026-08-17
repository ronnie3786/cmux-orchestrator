import Testing
@testable import herdr_harness_ios

@Suite("Pi prompt composer configuration")
struct PiPromptComposerConfigurationTests {
    @Test("Idle Pi sessions accept a standard prompt")
    func idleUsesPrompt() {
        let configuration = makeConfiguration(phase: .idle)

        #expect(configuration.availableDispositions == [.prompt])
        #expect(configuration.preferredDisposition == .prompt)
        #expect(configuration.placeholder(for: .prompt) == "Message Pi")
        #expect(!configuration.canAbort)
    }

    @Test("Working Pi sessions offer steer and follow-up without disrupting the current turn")
    func workingUsesLiveDispositions() {
        let configuration = makeConfiguration(phase: .working)

        #expect(configuration.availableDispositions == [.steer, .followUp])
        #expect(configuration.preferredDisposition == .steer)
        #expect(configuration.placeholder(for: .steer) == "Steer this turn")
        #expect(configuration.placeholder(for: .followUp) == "Queue a follow-up")
        #expect(configuration.canAbort)
    }

    @Test("Prompt remains a safe fallback when live dispositions are unavailable")
    func workingFallsBackToPrompt() {
        let configuration = makeConfiguration(
            phase: .working,
            capabilities: PiSemanticCapabilities(
                prompt: true,
                steer: false,
                followUp: false,
                abort: false,
                listModels: false,
                setModel: false,
                interactionResponse: false
            )
        )

        #expect(configuration.availableDispositions == [.prompt])
        #expect(!configuration.canAbort)
    }

    @Test("An offline bridge disables submission and stop controls")
    func offlineDisablesActions() {
        let configuration = makeConfiguration(phase: .working, isConnected: false)

        #expect(configuration.availableDispositions.isEmpty)
        #expect(configuration.placeholder(for: .steer) == "Pi is offline")
        #expect(!configuration.canAbort)
    }

    @Test("Known models remain read-only when model capabilities are unavailable")
    func unavailableModelCapabilitiesDoNotSupportMenu() {
        let configuration = makeConfiguration(
            phase: .idle,
            capabilities: PiSemanticCapabilities(
                prompt: true,
                steer: true,
                followUp: true,
                abort: true,
                listModels: false,
                setModel: false,
                interactionResponse: true
            ),
            currentModel: PiModelIdentity(provider: "anthropic", id: "claude-3", name: "Claude 3")
        )

        #expect(!configuration.supportsModelMenu)
    }

    @Test("Available model capabilities support the model menu")
    func availableModelCapabilitiesSupportMenu() {
        let configuration = makeConfiguration(phase: .idle)

        #expect(configuration.supportsModelMenu)
    }

    @Test("Unsupported model switching overrides available model capabilities")
    func unsupportedModelSwitchingDoesNotSupportMenu() {
        let configuration = makeConfiguration(
            phase: .idle,
            isModelSwitchingUnsupported: true
        )

        #expect(!configuration.supportsModelMenu)
    }

    private func makeConfiguration(
        phase: PiConversationPhase,
        capabilities: PiSemanticCapabilities = PiSemanticCapabilities(
            prompt: true,
            steer: true,
            followUp: true,
            abort: true,
            listModels: true,
            setModel: true,
            interactionResponse: true
        ),
        isConnected: Bool = true,
        currentModel: PiModelIdentity? = nil,
        isModelSwitchingUnsupported: Bool = false
    ) -> PiPromptComposerConfiguration {
        PiPromptComposerConfiguration(
            capabilities: capabilities,
            phase: phase,
            isConnected: isConnected,
            isSubmitting: false,
            isAborting: false,
            currentModel: currentModel,
            availableModels: [],
            isLoadingModels: false,
            isSettingModel: false,
            modelCatalogError: nil,
            isModelSwitchingUnsupported: isModelSwitchingUnsupported,
            submit: { _, _ in true },
            abort: { true },
            selectModel: { _ in true },
            retryLoadModels: {}
        )
    }
}
