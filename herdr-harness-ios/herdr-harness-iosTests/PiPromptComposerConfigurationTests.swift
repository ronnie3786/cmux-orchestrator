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
                setThinkingLevel: false,
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

    @Test("Compaction disables prompt, stop, model, and thinking controls with a reason-aware status")
    func compactionDisablesActions() {
        let cases: [(PiCompactionActivity, String)] = [
            (PiCompactionActivity(reason: .manual, willRetry: false), "Compacting context…"),
            (PiCompactionActivity(reason: .threshold, willRetry: false), "Compacting context automatically…"),
            (
                PiCompactionActivity(reason: .overflow, willRetry: true),
                "Compacting context after overflow, then retrying…"
            ),
        ]

        for (activity, status) in cases {
            let configuration = makeConfiguration(
                phase: .working,
                compactionActivity: activity
            )

            #expect(configuration.availableDispositions.isEmpty)
            #expect(!configuration.canAbort)
            #expect(!configuration.canSelectModel)
            #expect(!configuration.canSelectThinkingLevel)
            #expect(configuration.placeholder(for: .prompt) == "Pi is compacting context")
            #expect(activity.statusMessage == status)
        }
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
                setThinkingLevel: false,
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

    @Test("Thinking capability controls whether the thinking menu is supported")
    func unavailableThinkingCapabilityDoesNotSupportMenu() {
        let configuration = makeConfiguration(
            phase: .idle,
            capabilities: PiSemanticCapabilities(
                prompt: true,
                steer: true,
                followUp: true,
                abort: true,
                listModels: true,
                setModel: true,
                setThinkingLevel: false,
                interactionResponse: true
            )
        )

        #expect(!configuration.supportsThinkingMenu)
    }

    @Test("Known non-reasoning models do not support the thinking menu")
    func nonReasoningModelDoesNotSupportThinkingMenu() {
        let configuration = makeConfiguration(
            phase: .idle,
            currentModel: PiModelIdentity(provider: "openai", id: "gpt-5", name: "GPT-5"),
            availableModels: [
                PiAvailableModel(
                    provider: "openai",
                    modelID: "gpt-5",
                    name: "GPT-5",
                    reasoning: false,
                    contextWindow: nil
                )
            ]
        )

        #expect(!configuration.supportsThinkingMenu)
    }

    @Test("Reasoning models support the thinking menu")
    func reasoningModelSupportsThinkingMenu() {
        let configuration = makeConfiguration(
            phase: .idle,
            currentModel: PiModelIdentity(provider: "openai", id: "gpt-5", name: "GPT-5"),
            availableModels: [
                PiAvailableModel(
                    provider: "openai",
                    modelID: "gpt-5",
                    name: "GPT-5",
                    reasoning: true,
                    contextWindow: nil
                )
            ]
        )

        #expect(configuration.supportsThinkingMenu)
    }

    private func makeConfiguration(
        phase: PiConversationPhase,
        compactionActivity: PiCompactionActivity? = nil,
        capabilities: PiSemanticCapabilities = PiSemanticCapabilities(
            prompt: true,
            steer: true,
            followUp: true,
            abort: true,
            listModels: true,
            setModel: true,
            setThinkingLevel: true,
            interactionResponse: true
        ),
        isConnected: Bool = true,
        currentModel: PiModelIdentity? = nil,
        thinkingLevel: String? = nil,
        isSettingThinkingLevel: Bool = false,
        availableModels: [PiAvailableModel] = [],
        isModelSwitchingUnsupported: Bool = false
    ) -> PiPromptComposerConfiguration {
        PiPromptComposerConfiguration(
            capabilities: capabilities,
            phase: phase,
            compactionActivity: compactionActivity,
            isConnected: isConnected,
            isSubmitting: false,
            isAborting: false,
            currentModel: currentModel,
            availableModels: availableModels,
            isLoadingModels: false,
            isSettingModel: false,
            modelCatalogError: nil,
            isModelSwitchingUnsupported: isModelSwitchingUnsupported,
            submit: { _, _ in true },
            abort: { true },
            selectModel: { _ in true },
            retryLoadModels: {},
            thinkingLevel: thinkingLevel,
            isSettingThinkingLevel: isSettingThinkingLevel,
            selectThinkingLevel: { _ in true }
        )
    }
}
