import Foundation
import Observation

// These are the app-side defaults for headless agent runs in the HUD and quick
// chat. An empty model string means send no model, letting the harness's own pi
// default win. The vision and thinking defaults used to be compile-time
// constants in HerdrHudModelRouting.
struct AgentModelSettings: Equatable, Sendable {
    // The HUD keeps its original key: the HUD's own chip has always written
    // here, and Settings is a second surface onto the same value, not a
    // competing one. A user who picks a model in the HUD sees it in Settings.
    static let hudModelKey = "herdr.hud.model"
    static let quickChatModelKey = "herdr.agent.model"
    static let visionModelKey = "herdr.agent.visionModel"
    static let thinkingLevelKey = "herdr.agent.thinkingLevel"

    /// The model every image-bearing HUD message is rerouted to when the
    /// chosen model cannot see images. Was `HerdrHudModelRouting.visionModel`.
    static let builtInVisionModel = "openai-codex/gpt-5.6-luna"
    static let builtInThinkingLevel = PiThinkingLevel.max

    var hudModel: String
    var quickChatModel: String
    var visionModel: String
    var thinkingLevel: PiThinkingLevel

    static func load(from defaults: UserDefaults) -> AgentModelSettings {
        AgentModelSettings(
            hudModel: defaults.string(forKey: hudModelKey) ?? "",
            quickChatModel: defaults.string(forKey: quickChatModelKey) ?? "",
            visionModel: defaults.string(forKey: visionModelKey) ?? "",
            thinkingLevel: PiThinkingLevel(
                rawValue: defaults.string(forKey: thinkingLevelKey) ?? ""
            ) ?? .max
        )
    }

    func save(to defaults: UserDefaults) {
        defaults.set(hudModel, forKey: Self.hudModelKey)
        defaults.set(quickChatModel, forKey: Self.quickChatModelKey)
        defaults.set(visionModel, forKey: Self.visionModelKey)
        defaults.set(thinkingLevel.rawValue, forKey: Self.thinkingLevelKey)
    }

    /// The vision model actually sent, never empty.
    var effectiveVisionModel: String {
        visionModel.isEmpty ? Self.builtInVisionModel : visionModel
    }
}

@MainActor
@Observable
final class AgentModelSettingsStore {
    var hudModel: String {
        didSet { saveIfChanged(oldValue != hudModel) }
    }
    var quickChatModel: String {
        didSet { saveIfChanged(oldValue != quickChatModel) }
    }
    var visionModel: String {
        didSet { saveIfChanged(oldValue != visionModel) }
    }
    var thinkingLevel: PiThinkingLevel {
        didSet { saveIfChanged(oldValue != thinkingLevel) }
    }

    var effectiveVisionModel: String {
        visionModel.isEmpty ? AgentModelSettings.builtInVisionModel : visionModel
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let settings = AgentModelSettings.load(from: defaults)
        hudModel = settings.hudModel
        quickChatModel = settings.quickChatModel
        visionModel = settings.visionModel
        thinkingLevel = settings.thinkingLevel
    }

    private func saveIfChanged(_ changed: Bool) {
        guard changed else { return }
        AgentModelSettings(
            hudModel: hudModel,
            quickChatModel: quickChatModel,
            visionModel: visionModel,
            thinkingLevel: thinkingLevel
        ).save(to: defaults)
    }
}
