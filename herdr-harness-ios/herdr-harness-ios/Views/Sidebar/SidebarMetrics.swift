import SwiftUI

/// Indent ladder and row heights for the navigator drawer. Kept here so the
/// rows and the group titles that align with them cannot drift apart.
///
/// Type sizes deliberately live at the call sites as Dynamic Type text styles
/// (`.subheadline` / `.caption` / `.caption2`) rather than as fixed point sizes
/// here: iOS scales those for the reader, so there is nothing to pin down.
/// The indent ladder is deliberately tighter than it looks like it should be.
/// The drawer is `min(340, width * 0.86)`, so on a 393pt phone a chat row has
/// ~338pt to work with — an earlier 10 + 34 indent spent 13% of that on empty
/// space before the status dot, and chat titles truncated that much sooner.
/// The steps are uneven on purpose. A workspace row leads with a chevron and a
/// tab row with a narrower folder glyph, so equal padding steps render as an
/// almost-flat tab-to-chat transition; the chat row needs the wider gap to read
/// as nested under its tab.
enum SidebarMetrics {
    static let containerHorizontalPadding: CGFloat = 8
    static let rowTrailingPadding: CGFloat = 10
    static let workspaceRowLeadingPadding: CGFloat = 8
    static let tabRowLeadingPadding: CGFloat = 12
    static let chatRowLeadingPadding: CGFloat = 20

    /// Every row is at least a 44pt touch target; the workspace and machine
    /// rows sit taller because they head a group.
    static let projectRowHeight: CGFloat = 48
    static let machineRowHeight: CGFloat = 48
    static let tabRowHeight: CGFloat = 44
    static let chatRowHeight: CGFloat = 44
    static let placeholderRowHeight: CGFloat = 36
}
