import AppKit
import SwiftUI

enum HerdrTheme {
    // Catppuccin Mocha, Herdr's default terminal palette.
    static let ink = Color(red: 0.094, green: 0.094, blue: 0.145)
    static let graphite = Color(red: 0.118, green: 0.118, blue: 0.180)
    static let elevated = Color(red: 0.192, green: 0.196, blue: 0.267)
    static let surface = Color(red: 0.271, green: 0.278, blue: 0.353)
    static let mist = Color(red: 0.651, green: 0.678, blue: 0.784)
    static let muted = Color(red: 0.424, green: 0.439, blue: 0.525)
    static let text = Color(red: 0.804, green: 0.839, blue: 0.957)
    static let accent = Color(red: 0.537, green: 0.706, blue: 0.980)
    static let mauve = Color(red: 0.796, green: 0.651, blue: 0.969)
    static let signal = Color(red: 0.580, green: 0.886, blue: 0.835)
    static let success = Color(red: 0.651, green: 0.890, blue: 0.631)
    static let working = Color(red: 0.976, green: 0.886, blue: 0.686)
    static let alert = Color(red: 0.953, green: 0.545, blue: 0.659)
    static let warning = Color(red: 0.980, green: 0.702, blue: 0.529)

    static let cardRadius = 16.0
    static let compactRadius = 10.0
    static let pagePadding = 18.0
    static let cardPadding = 16.0
    static let rowSpacing = 12.0
}

extension HerdrTheme {
    /// Fallback font scaling: Apple documents `dynamicTypeSize` as having no
    /// effect on text size on macOS. Read AppKit's preferred point size and
    /// rebuild a concrete SwiftUI font scaled by the user's chosen value.
    static func scaled(
        _ style: Font.TextStyle,
        scale: HerdrFontScale,
        monospaced: Bool = false,
        weight: Font.Weight? = nil
    ) -> Font {
        let base = NSFont.preferredFont(forTextStyle: style.appKitTextStyle)
        return .system(
            size: base.pointSize * scale.rawValue,
            weight: weight ?? base.herdrFontWeight,
            design: monospaced ? .monospaced : .default
        )
    }
}

private extension NSFont {
    var herdrFontWeight: Font.Weight {
        let traits = fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        let value = (traits?[.weight] as? NSNumber)?.doubleValue ?? 0
        let named: [(CGFloat, Font.Weight)] = [
            (NSFont.Weight.ultraLight.rawValue, .ultraLight),
            (NSFont.Weight.thin.rawValue, .thin),
            (NSFont.Weight.light.rawValue, .light),
            (NSFont.Weight.regular.rawValue, .regular),
            (NSFont.Weight.medium.rawValue, .medium),
            (NSFont.Weight.semibold.rawValue, .semibold),
            (NSFont.Weight.bold.rawValue, .bold),
            (NSFont.Weight.heavy.rawValue, .heavy),
            (NSFont.Weight.black.rawValue, .black),
        ]
        return named.min {
            abs($0.0 - CGFloat(value)) < abs($1.0 - CGFloat(value))
        }?.1 ?? .regular
    }
}

private extension Font.TextStyle {
    var appKitTextStyle: NSFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        @unknown default: .body
        }
    }
}
