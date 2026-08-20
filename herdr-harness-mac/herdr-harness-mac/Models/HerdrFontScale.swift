import Foundation
import Observation
import SwiftUI

/// The discrete text-size choices Herdr offers on macOS.
enum HerdrFontScale: Double, CaseIterable, Codable, Sendable, Comparable, Identifiable {
    case small = 0.9
    case medium = 1.0
    case large = 1.1
    case xLarge = 1.25
    case xxLarge = 1.4
    case xxxLarge = 1.6

    static let `default`: HerdrFontScale = .medium
    static let defaultsKey = "herdr.mac.fontScale"

    var id: Double { rawValue }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        "\(Int((rawValue * 100).rounded()))%"
    }

    func stepped(by delta: Int) -> HerdrFontScale {
        let cases = Self.allCases
        guard let index = cases.firstIndex(of: self) else { return .default }
        let clampedIndex = min(max(index + delta, 0), cases.count - 1)
        return cases[clampedIndex]
    }

    var increased: HerdrFontScale { stepped(by: 1) }
    var decreased: HerdrFontScale { stepped(by: -1) }

    /// Loads the stored value, accepting old or manually written values by
    /// snapping them to the closest supported step.
    static func load(from defaults: UserDefaults) -> HerdrFontScale {
        guard let storedValue = defaults.object(forKey: Self.defaultsKey) as? NSNumber else {
            return .default
        }

        let rawValue = storedValue.doubleValue
        return Self.allCases.min { lhs, rhs in
            abs(lhs.rawValue - rawValue) < abs(rhs.rawValue - rawValue)
        } ?? .default
    }

    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

@MainActor
@Observable
final class HerdrFontScaleStore {
    var scale: HerdrFontScale {
        didSet {
            guard oldValue != scale else { return }
            scale.save(to: defaults)
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.scale = HerdrFontScale.load(from: defaults)
    }

    func increase() {
        scale = scale.increased
    }

    func decrease() {
        scale = scale.decreased
    }

    func reset() {
        scale = .default
    }
}

private struct HerdrFontScaleEnvironmentKey: EnvironmentKey {
    static let defaultValue: HerdrFontScale = .default
}

extension EnvironmentValues {
    var herdrFontScale: HerdrFontScale {
        get { self[HerdrFontScaleEnvironmentKey.self] }
        set { self[HerdrFontScaleEnvironmentKey.self] = newValue }
    }
}
