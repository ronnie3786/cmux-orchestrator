import SwiftUI

enum HerdrTheme {
    // Catppuccin Mocha, Herdr's default terminal palette.
    static let ink = Color(red: 0.094, green: 0.094, blue: 0.145)
    static let graphite = Color(red: 0.118, green: 0.118, blue: 0.180)
    static let elevated = Color(red: 0.192, green: 0.196, blue: 0.267)
    static let surface = Color(red: 0.271, green: 0.278, blue: 0.353)
    static let mist = Color(red: 0.651, green: 0.678, blue: 0.784)
    static let muted = Color(red: 0.424, green: 0.439, blue: 0.525)
    static let text = Color(red: 0.898, green: 0.918, blue: 0.980)     // ≈ #E5EAFA
    static let accent = Color(red: 0.537, green: 0.706, blue: 0.980)
    static let mauve = Color(red: 0.796, green: 0.651, blue: 0.969)
    static let signal = Color(red: 0.580, green: 0.886, blue: 0.835)
    static let success = Color(red: 0.651, green: 0.890, blue: 0.631)
    static let working = Color(red: 0.976, green: 0.886, blue: 0.686)
    static let alert = Color(red: 0.953, green: 0.545, blue: 0.659)
    static let diffAdd = Color(red: 0.180, green: 0.627, blue: 0.263)
    static let diffRemove = Color(red: 0.973, green: 0.318, blue: 0.286)
    static let diffHunk = Color(red: 0.220, green: 0.545, blue: 0.992)
    static let warning = Color(red: 0.980, green: 0.702, blue: 0.529)
    static let code = Color(red: 0.961, green: 0.761, blue: 0.906)     // ≈ #F5C2E7
    static let crust = Color(red: 0.067, green: 0.067, blue: 0.106)     // ≈ #11111B

    static let cardRadius = 16.0
    static let compactRadius = 10.0
    static let pagePadding = 18.0
    static let cardPadding = 16.0
    static let rowSpacing = 12.0
}
