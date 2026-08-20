import SwiftUI

extension View {
    func herdrFont(
        _ style: Font.TextStyle,
        monospaced: Bool = false,
        weight: Font.Weight? = nil,
        monospacedDigit: Bool = false
    ) -> some View {
        modifier(
            HerdrTextStyleFontModifier(
                style: style,
                monospaced: monospaced,
                weight: weight,
                monospacedDigit: monospacedDigit
            )
        )
    }

    func herdrFont(
        size: CGFloat,
        monospaced: Bool = false,
        weight: Font.Weight? = nil,
        relativeTo: Font.TextStyle = .body
    ) -> some View {
        modifier(
            HerdrFixedSizeFontModifier(
                size: size,
                monospaced: monospaced,
                weight: weight,
                relativeTo: relativeTo
            )
        )
    }
}

private struct HerdrTextStyleFontModifier: ViewModifier {
    let style: Font.TextStyle
    let monospaced: Bool
    let weight: Font.Weight?
    let monospacedDigit: Bool
    @Environment(\.herdrFontScale) private var fontScale

    func body(content: Content) -> some View {
        var font = HerdrTheme.scaled(
            style,
            scale: fontScale,
            monospaced: monospaced,
            weight: weight
        )
        if monospacedDigit {
            font = font.monospacedDigit()
        }
        return content.font(font)
    }
}

private struct HerdrFixedSizeFontModifier: ViewModifier {
    let size: CGFloat
    let monospaced: Bool
    let weight: Font.Weight?
    let relativeTo: Font.TextStyle
    @Environment(\.herdrFontScale) private var fontScale

    func body(content: Content) -> some View {
        let _ = relativeTo
        return content.font(
            .system(
                size: size * fontScale.rawValue,
                weight: weight ?? .regular,
                design: monospaced ? .monospaced : .default
            )
        )
    }
}
