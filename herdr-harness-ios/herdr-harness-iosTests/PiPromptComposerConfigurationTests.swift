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

    private func makeConfiguration(
        phase: PiConversationPhase,
        capabilities: PiSemanticCapabilities = PiSemanticCapabilities(
            prompt: true,
            steer: true,
            followUp: true,
            abort: true,
            interactionResponse: true
        ),
        isConnected: Bool = true
    ) -> PiPromptComposerConfiguration {
        PiPromptComposerConfiguration(
            capabilities: capabilities,
            phase: phase,
            isConnected: isConnected,
            isSubmitting: false,
            isAborting: false,
            submit: { _, _ in true },
            abort: { true }
        )
    }
}
