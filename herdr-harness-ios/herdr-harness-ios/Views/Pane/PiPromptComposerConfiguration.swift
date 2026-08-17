import Foundation

/// Live Pi state and actions used when the shared prompt composer is presented
/// below the semantic transcript instead of the terminal.
struct PiPromptComposerConfiguration {
    let capabilities: PiSemanticCapabilities
    let phase: PiConversationPhase
    let isConnected: Bool
    let isSubmitting: Bool
    let isAborting: Bool
    let currentModel: PiModelIdentity?
    let availableModels: [PiAvailableModel]
    let isLoadingModels: Bool
    let isSettingModel: Bool
    let modelCatalogError: String?
    let isModelSwitchingUnsupported: Bool
    let submit: (String, PiPromptDisposition) async -> Bool
    let abort: () async -> Bool
    let selectModel: (PiAvailableModel) async -> Bool
    let retryLoadModels: () async -> Void

    var availableDispositions: [PiPromptDisposition] {
        guard isConnected else { return [] }
        guard phase == .working else {
            return capabilities.prompt ? [.prompt] : []
        }

        var dispositions: [PiPromptDisposition] = []
        if capabilities.steer { dispositions.append(.steer) }
        if capabilities.followUp { dispositions.append(.followUp) }
        if dispositions.isEmpty, capabilities.prompt { dispositions.append(.prompt) }
        return dispositions
    }

    var preferredDisposition: PiPromptDisposition {
        availableDispositions.first ?? .prompt
    }

    var canAbort: Bool {
        phase == .working && isConnected && capabilities.abort && !isAborting
    }

    var canSelectModel: Bool {
        capabilities.setModel && isConnected && !isSettingModel
    }

    var supportsModelMenu: Bool {
        capabilities.listModels && capabilities.setModel && !isModelSwitchingUnsupported
    }

    func placeholder(for disposition: PiPromptDisposition) -> String {
        guard isConnected else { return "Pi is offline" }
        return switch disposition {
        case .prompt: "Message Pi"
        case .steer: "Steer this turn"
        case .followUp: "Queue a follow-up"
        }
    }
}
