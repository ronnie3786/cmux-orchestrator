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
    static let hudThinkingLevelKey = "herdr.hud.thinkingLevel"
    /// Quick chat keeps the key the shared setting used, so an existing choice
    /// carries over instead of silently resetting to the built-in default.
    static let quickChatThinkingLevelKey = "herdr.agent.thinkingLevel"
    static let notesModelKey = "herdr.notes.model"
    static let notesThinkingLevelKey = "herdr.notes.thinkingLevel"

    /// The model every image-bearing HUD message is rerouted to when the
    /// chosen model cannot see images. Was `HerdrHudModelRouting.visionModel`.
    static let builtInVisionModel = "openai-codex/gpt-5.6-luna"
    static let builtInThinkingLevel = PiThinkingLevel.max

    var hudModel: String
    var quickChatModel: String
    var visionModel: String
    var hudThinkingLevel: PiThinkingLevel
    var quickChatThinkingLevel: PiThinkingLevel
    var notesModel: String
    var notesThinkingLevel: PiThinkingLevel

    static func load(from defaults: UserDefaults) -> AgentModelSettings {
        let legacy = defaults.string(forKey: quickChatThinkingLevelKey)
        let hudRaw = defaults.string(forKey: hudThinkingLevelKey) ?? legacy
        return AgentModelSettings(
            hudModel: defaults.string(forKey: hudModelKey) ?? "",
            quickChatModel: defaults.string(forKey: quickChatModelKey) ?? "",
            visionModel: defaults.string(forKey: visionModelKey) ?? "",
            hudThinkingLevel: PiThinkingLevel(rawValue: hudRaw ?? "") ?? builtInThinkingLevel,
            quickChatThinkingLevel: PiThinkingLevel(rawValue: legacy ?? "") ?? builtInThinkingLevel,
            notesModel: defaults.string(forKey: notesModelKey) ?? "",
            notesThinkingLevel: PiThinkingLevel(rawValue: defaults.string(forKey: notesThinkingLevelKey) ?? "") ?? .medium
        )
    }

    func save(to defaults: UserDefaults) {
        defaults.set(hudModel, forKey: Self.hudModelKey)
        defaults.set(quickChatModel, forKey: Self.quickChatModelKey)
        defaults.set(visionModel, forKey: Self.visionModelKey)
        defaults.set(hudThinkingLevel.rawValue, forKey: Self.hudThinkingLevelKey)
        defaults.set(quickChatThinkingLevel.rawValue, forKey: Self.quickChatThinkingLevelKey)
        defaults.set(notesModel, forKey: Self.notesModelKey)
        defaults.set(notesThinkingLevel.rawValue, forKey: Self.notesThinkingLevelKey)
    }

    /// The vision model actually sent, never empty.
    var effectiveVisionModel: String {
        visionModel.isEmpty ? Self.builtInVisionModel : visionModel
    }

    var effectiveNotesModel: String? {
        if !notesModel.isEmpty { return notesModel }
        if !hudModel.isEmpty { return hudModel }
        return nil
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
    var hudThinkingLevel: PiThinkingLevel {
        didSet { saveIfChanged(oldValue != hudThinkingLevel) }
    }
    var quickChatThinkingLevel: PiThinkingLevel {
        didSet { saveIfChanged(oldValue != quickChatThinkingLevel) }
    }
    var notesModel: String {
        didSet { saveIfChanged(oldValue != notesModel) }
    }
    var notesThinkingLevel: PiThinkingLevel {
        didSet { saveIfChanged(oldValue != notesThinkingLevel) }
    }

    var effectiveVisionModel: String {
        visionModel.isEmpty ? AgentModelSettings.builtInVisionModel : visionModel
    }

    var effectiveNotesModel: String? {
        if !notesModel.isEmpty { return notesModel }
        if !hudModel.isEmpty { return hudModel }
        return nil
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let settings = AgentModelSettings.load(from: defaults)
        hudModel = settings.hudModel
        quickChatModel = settings.quickChatModel
        visionModel = settings.visionModel
        hudThinkingLevel = settings.hudThinkingLevel
        quickChatThinkingLevel = settings.quickChatThinkingLevel
        notesModel = settings.notesModel
        notesThinkingLevel = settings.notesThinkingLevel
    }

    private func saveIfChanged(_ changed: Bool) {
        guard changed else { return }
        AgentModelSettings(
            hudModel: hudModel,
            quickChatModel: quickChatModel,
            visionModel: visionModel,
            hudThinkingLevel: hudThinkingLevel,
            quickChatThinkingLevel: quickChatThinkingLevel,
            notesModel: notesModel,
            notesThinkingLevel: notesThinkingLevel
        ).save(to: defaults)
    }
}
