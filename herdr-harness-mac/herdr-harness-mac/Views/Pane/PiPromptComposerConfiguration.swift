import Foundation

/// Live Pi state and actions used when the shared prompt composer is presented
/// below the semantic transcript instead of the terminal.
struct PiPromptComposerConfiguration {
    let capabilities: PiSemanticCapabilities
    let phase: PiConversationPhase
    let compactionActivity: PiCompactionActivity?
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
    let thinkingLevel: String?
    let isSettingThinkingLevel: Bool
    let selectThinkingLevel: (PiThinkingLevel) async -> Bool

    var isCompacting: Bool {
        compactionActivity != nil
    }

    var availableDispositions: [PiPromptDisposition] {
        guard isConnected, !isCompacting else { return [] }
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
        phase == .working && isConnected && capabilities.abort && !isAborting && !isCompacting
    }

    var canSelectModel: Bool {
        capabilities.setModel && isConnected && !isSettingModel && !isCompacting
    }

    var canSelectThinkingLevel: Bool {
        capabilities.setThinkingLevel && isConnected && !isSettingThinkingLevel && !isCompacting
    }

    var supportsModelMenu: Bool {
        capabilities.listModels && capabilities.setModel && !isModelSwitchingUnsupported
    }

    var supportsThinkingMenu: Bool {
        guard capabilities.setThinkingLevel else { return false }
        guard let current = currentModel,
              let reasoning = availableModels.first(
                where: { $0.provider == current.provider && $0.modelID == current.id }
              )?.reasoning
        else { return true }
        return reasoning
    }

    func placeholder(for disposition: PiPromptDisposition) -> String {
        guard isConnected else { return "Pi is offline" }
        if isCompacting { return "Pi is compacting context" }
        return switch disposition {
        case .prompt: "Message Pi"
        case .steer: "Steer this turn"
        case .followUp: "Queue a follow-up"
        }
    }
}

extension PiPromptComposerConfiguration: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.capabilities == rhs.capabilities
            && lhs.phase == rhs.phase
            && lhs.compactionActivity == rhs.compactionActivity
            && lhs.isConnected == rhs.isConnected
            && lhs.isSubmitting == rhs.isSubmitting
            && lhs.isAborting == rhs.isAborting
            && lhs.currentModel == rhs.currentModel
            && lhs.availableModels == rhs.availableModels
            && lhs.isLoadingModels == rhs.isLoadingModels
            && lhs.isSettingModel == rhs.isSettingModel
            && lhs.modelCatalogError == rhs.modelCatalogError
            && lhs.isModelSwitchingUnsupported == rhs.isModelSwitchingUnsupported
            && lhs.thinkingLevel == rhs.thinkingLevel
            && lhs.isSettingThinkingLevel == rhs.isSettingThinkingLevel
    }
}
