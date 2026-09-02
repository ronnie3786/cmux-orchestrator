import AppKit
import SwiftUI

/// Typography for Pi's rendered assistant OUTPUT prose: the markdown message
/// body (paragraphs, headings, lists, quotes, tables). This is the seam that
/// makes Pi's actual output visually unmistakable versus the surrounding
/// chrome — output renders in Inter at full contrast, while thinking
/// disclosures and tool cards (`PiThinkingDisclosureView`, `PiToolCardView`,
/// `PiWorkingGroupView`)
/// keep their existing system/mono fonts and instead turn visually recessive
/// via `subOutputOpacity`. Code blocks stay monospaced everywhere; they're
/// code, not prose.
enum HerdrProse {
    /// A semantic role within Pi's rendered markdown output.
    enum Role: CaseIterable, Sendable {
        case body
        case quote
        case listItem
        case heading1
        case heading2
        case heading3
        case heading4
        case heading5
        case heading6
        case tableHeader
        case tableCell

        /// Base point size at 100% font scale (before `HerdrFontScale`).
        var baseSize: CGFloat {
            switch self {
            case .body, .quote, .listItem: 15
            case .heading1: 20
            case .heading2: 17
            case .heading3: 15
            case .heading4: 13
            case .heading5: 12
            case .heading6: 11
            case .tableHeader, .tableCell: 14
            }
        }

        var weight: Font.Weight {
            switch self {
            case .body, .quote, .listItem, .tableCell: .regular
            case .heading1, .heading2, .heading3: .semibold
            case .heading4: .semibold
            case .heading5, .heading6: .semibold
            case .tableHeader: .semibold
            }
        }

        /// Block quotes render in Inter's real italic face rather than a
        /// synthetic slant.
        var isItalic: Bool { self == .quote }
    }

    /// Spacing between adjacent markdown blocks (paragraph, heading, list,
    /// quote, table, code) inside a single rendered message.
    static let blockSpacing: CGFloat = 12

    /// Spacing between conversation turns in `PiChatTimelineView`.
    static let turnSpacing: CGFloat = 28

    /// How far "sub-output" cards — thinking disclosures, tool cards, and
    /// working groups — are dimmed so they read as visually recessive relative
    /// to Pi's actual output prose. Applied to the cards' foreground colours
    /// (`dimmed(_:)`), never as `.opacity` on the whole card: a group-opacity
    /// on each of a hundred cards cost ~170 ms per card per layout pass.
    static let subOutputOpacity: Double = 0.78

    /// A card foreground colour at `subOutputOpacity`.
    static func dimmed(_ color: Color) -> Color {
        color.opacity(subOutputOpacity)
    }

    /// Inter font for a role, scaled by the user's global font-scale
    /// preference (`HerdrFontScale`), mirroring `HerdrTheme.scaled` /
    /// `.herdrFont`. `Font.custom` falls back to the system font at the same
    /// size if Inter isn't resolvable, so this degrades gracefully.
    static func font(_ role: Role, scale: HerdrFontScale) -> Font {
        .custom(postScriptName(for: role), size: role.baseSize * scale.rawValue)
    }

    /// Monospaced chip font for inline `code` spans within prose, sized
    /// relative to the surrounding role and the user's font-scale preference.
    static func inlineCodeFont(_ role: Role, scale: HerdrFontScale) -> Font {
        .system(size: (role.baseSize * 0.9 * scale.rawValue).rounded(), weight: .medium, design: .monospaced)
    }

    /// Foreground color for inline `code` spans within prose.
    static let inlineCodeColor: Color = HerdrTheme.code

    /// `.lineSpacing(...)` for reading-prose roles (body, quote, list items)
    /// at the given scale. Call sites for headings and tables keep their own
    /// existing tight spacing instead of calling this.
    static func lineSpacing(_ role: Role, scale: HerdrFontScale) -> CGFloat {
        (role.baseSize * scale.rawValue * 0.35).rounded()
    }

    /// Extra space ABOVE a heading, added on top of `blockSpacing`, so
    /// headings read as new sections rather than just another paragraph.
    static func headingTopSpacing(_ level: Int) -> CGFloat {
        switch level {
        case ...2: 12
        case 3: 6
        default: 2
        }
    }

    private static func postScriptName(for role: Role) -> String {
        if role.isItalic { return "Inter-Italic" }
        switch role.weight {
        case .bold, .heavy, .black: return "Inter-Bold"
        case .semibold: return "Inter-SemiBold"
        case .medium: return "Inter-Medium"
        default: return "Inter-Regular"
        }
    }

    /// Runtime check that the bundled Inter-Regular face actually resolves.
    /// Used by a unit test to catch bundling regressions (e.g. a missing
    /// Fonts/ resource or a stale `ATSApplicationFontsPath`) in CI.
    static func isInterRegularAvailable() -> Bool {
        NSFont(name: "Inter-Regular", size: 12) != nil
    }
}
