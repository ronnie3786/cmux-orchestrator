import SwiftUI

/// Indent ladder and row heights for the navigator drawer. Kept here so the
/// rows and the group titles that align with them cannot drift apart.
///
/// Type sizes deliberately live at the call sites as Dynamic Type text styles
/// (`.subheadline` / `.caption` / `.caption2`) rather than as fixed point sizes
/// here: iOS scales those for the reader, so there is nothing to pin down.
enum SidebarMetrics {
    static let containerHorizontalPadding: CGFloat = 10
    static let rowTrailingPadding: CGFloat = 12
    static let workspaceRowLeadingPadding: CGFloat = 12
    static let tabRowLeadingPadding: CGFloat = 18
    static let chatRowLeadingPadding: CGFloat = 34

    /// Every row is at least a 44pt touch target; the workspace and machine
    /// rows sit taller because they head a group.
    static let projectRowHeight: CGFloat = 48
    static let machineRowHeight: CGFloat = 48
    static let tabRowHeight: CGFloat = 44
    static let chatRowHeight: CGFloat = 44
    static let placeholderRowHeight: CGFloat = 36
}
