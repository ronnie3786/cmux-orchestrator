import SwiftUI
import UIKit

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

        /// Base point size before Dynamic Type scaling.
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

        /// The Dynamic Type anchor this role tracks, so accessibility text
        /// sizes still scale Inter output on iOS.
        var textStyle: Font.TextStyle {
            switch self {
            case .body, .quote, .listItem: .body
            case .heading1: .title2
            case .heading2: .title3
            case .heading3: .headline
            case .heading4: .subheadline
            case .heading5: .footnote
            case .heading6: .caption
            case .tableHeader, .tableCell: .callout
            }
        }
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

    /// Inter font for a role, anchored to its Dynamic Type text style via
    /// `Font.custom(_:size:relativeTo:)` so accessibility text sizes still
    /// scale it. `Font.custom` falls back to the system font at the same
    /// size if Inter isn't resolvable, so this degrades gracefully.
    static func font(_ role: Role) -> Font {
        .custom(postScriptName(for: role), size: role.baseSize, relativeTo: role.textStyle)
    }

    /// `.lineSpacing(...)` for reading-prose roles (body, quote, list items).
    /// Call sites for headings and tables keep their own existing tight
    /// spacing instead of calling this.
    static func lineSpacing(_ role: Role) -> CGFloat {
        (role.baseSize * 0.35).rounded()
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
    /// Fonts/ resource or a stale `UIAppFonts` entry) in CI.
    static func isInterRegularAvailable() -> Bool {
        UIFont(name: "Inter-Regular", size: 12) != nil
    }
}
