import Foundation
import Observation

@MainActor
@Observable
final class HerdrPromptSettingsStore {
    private(set) var harnessDefaults: [HerdrPromptID: String] = [:]
    private(set) var harnessSupportsOverrides: Bool?
    private(set) var revision = 0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var overrides: [HerdrPromptID: String] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for id in HerdrPromptID.allCases {
            if let stored = defaults.string(forKey: id.defaultsKey) {
                overrides[id] = stored
            }
        }
    }

    func defaultText(for id: HerdrPromptID) -> String {
        harnessDefaults[id] ?? id.builtInDefault
    }

    func text(for id: HerdrPromptID) -> String {
        override(for: id) ?? defaultText(for: id)
    }

    func isCustomized(_ id: HerdrPromptID) -> Bool {
        guard let override = overrides[id] else { return false }
        return override != defaultText(for: id)
    }

    func override(for id: HerdrPromptID) -> String? {
        Self.storedOverride(for: id, defaults: defaults)
    }

    static func storedOverride(for id: HerdrPromptID, defaults: UserDefaults) -> String? {
        guard let override = defaults.string(forKey: id.defaultsKey),
              !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return override
    }

    func setText(_ text: String, for id: HerdrPromptID) {
        if text == defaultText(for: id) {
            reset(id)
            return
        }
        guard overrides[id] != text else { return }
        overrides[id] = text
        defaults.set(text, forKey: id.defaultsKey)
        revision += 1
    }

    func reset(_ id: HerdrPromptID) {
        guard overrides[id] != nil else { return }
        overrides[id] = nil
        defaults.removeObject(forKey: id.defaultsKey)
        revision += 1
    }

    func loadHarnessDefaults(model: HerdrAppModel) async {
        do {
            let response = try await model.fetchAgentPromptDefaults()
            var mapped: [HerdrPromptID: String] = [:]
            if let act = response.prompts["act"] { mapped[.hudActCharter] = act }
            if let ask = response.prompts["ask"] { mapped[.agentAskCharter] = ask }
            if let judge = response.prompts["cleanupJudge"] { mapped[.cleanupJudgeCharter] = judge }
            harnessDefaults = mapped
            harnessSupportsOverrides = true
            revision += 1
        } catch is AgentPromptDefaultsError {
            harnessSupportsOverrides = false
            revision += 1
        } catch {
        }
    }
}
