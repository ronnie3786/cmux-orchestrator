import AppKit
import SwiftUI

/// Typography for Pi's rendered assistant OUTPUT prose: the markdown message
/// body (paragraphs, headings, lists, quotes, tables). This is the seam that
/// makes Pi's actual output visually unmistakable versus the surrounding
/// chrome — output renders in Inter at full contrast, while thinking
/// disclosures and tool cards (`PiThinkingDisclosureView`, `PiToolCardView`)
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
            case .heading1, .heading2, .heading3: .bold
            case .heading4: .semibold
            case .heading5, .heading6: .bold
            case .tableHeader: .semibold
            }
        }

        /// Block quotes render in Inter's real italic face rather than a
        /// synthetic slant.
        var isItalic: Bool { self == .quote }
    }

    /// Spacing between adjacent markdown blocks (paragraph, heading, list,
    /// quote, table, code) inside a single rendered message.
    static let blockSpacing: CGFloat = 9

    /// Spacing between conversation turns in `PiChatTimelineView`.
    static let turnSpacing: CGFloat = 28

    /// Opacity applied to whole "sub-output" cards — thinking disclosures and
    /// tool cards — so they read as visually recessive relative to Pi's
    /// actual output prose.
    static let subOutputOpacity: Double = 0.78

    /// Inter font for a role, scaled by the user's global font-scale
    /// preference (`HerdrFontScale`), mirroring `HerdrTheme.scaled` /
    /// `.herdrFont`. `Font.custom` falls back to the system font at the same
    /// size if Inter isn't resolvable, so this degrades gracefully.
    static func font(_ role: Role, scale: HerdrFontScale) -> Font {
        .custom(postScriptName(for: role), size: role.baseSize * scale.rawValue)
    }

    /// `.lineSpacing(...)` for reading-prose roles (body, quote, list items)
    /// at the given scale. Call sites for headings and tables keep their own
    /// existing tight spacing instead of calling this.
    static func lineSpacing(_ role: Role, scale: HerdrFontScale) -> CGFloat {
        (role.baseSize * scale.rawValue * 0.35).rounded()
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
