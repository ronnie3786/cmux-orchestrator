import Foundation
import Observation

enum CleanupThinkingLevel: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case off
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .medium
    }

    var label: String {
        switch self {
        case .off: "Off"
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "X-High"
        case .max: "Max"
        }
    }
}

struct CleanupSettings: Equatable, Sendable {
    static let modelKey = "herdr.cleanup.model"
    static let thinkingLevelKey = "herdr.cleanup.thinkingLevel"
    static let costThresholdUSDKey = "herdr.cleanup.costThresholdUSD"

    var model: String
    var thinkingLevel: CleanupThinkingLevel
    var costThresholdUSD: Double

    static func load(from defaults: UserDefaults) -> CleanupSettings {
        let model = defaults.string(forKey: modelKey) ?? ""
        let rawThinkingLevel = defaults.string(forKey: thinkingLevelKey) ?? CleanupThinkingLevel.medium.rawValue
        let threshold = defaults.object(forKey: costThresholdUSDKey) as? NSNumber
        return CleanupSettings(
            model: model,
            thinkingLevel: CleanupThinkingLevel(rawValue: rawThinkingLevel) ?? .medium,
            costThresholdUSD: threshold?.doubleValue ?? 2.0
        )
    }

    func save(to defaults: UserDefaults) {
        defaults.set(model, forKey: Self.modelKey)
        defaults.set(thinkingLevel.rawValue, forKey: Self.thinkingLevelKey)
        defaults.set(costThresholdUSD, forKey: Self.costThresholdUSDKey)
    }
}

@MainActor
@Observable
final class CleanupSettingsStore {
    var model: String {
        didSet { saveIfChanged(oldValue != model) }
    }
    var thinkingLevel: CleanupThinkingLevel {
        didSet { saveIfChanged(oldValue != thinkingLevel) }
    }
    var costThresholdUSD: Double {
        didSet { saveIfChanged(oldValue != costThresholdUSD) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let settings = CleanupSettings.load(from: defaults)
        model = settings.model
        thinkingLevel = settings.thinkingLevel
        costThresholdUSD = settings.costThresholdUSD
    }

    private func saveIfChanged(_ changed: Bool) {
        guard changed else { return }
        CleanupSettings(
            model: model,
            thinkingLevel: thinkingLevel,
            costThresholdUSD: costThresholdUSD
        ).save(to: defaults)
    }
}
