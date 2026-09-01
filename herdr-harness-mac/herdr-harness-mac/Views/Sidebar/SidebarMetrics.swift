import SwiftUI

enum SidebarMetrics {
    // Midpoints between the original 11/10/11/10pt sidebar typography and
    // icons and the first enlarged 16/15/16/13pt treatment.
    static let projectLabelSize: CGFloat = 13.5
    static let tabLabelSize: CGFloat = 12.5
    static let chatLabelSize: CGFloat = 13.5
    static let hierarchyIconSize: CGFloat = 11.5

    /// Halo behind the workspace status glyph. Sized to stay inside
    /// `projectRowHeight` (34) so the glow never bleeds into the row above.
    static let statusGlowDiameter: CGFloat = 18

    // Midpoints between the original 30/26/26pt rows and 38/34/34pt rows.
    static let projectRowHeight: CGFloat = 34
    static let tabRowHeight: CGFloat = 30
    static let chatRowHeight: CGFloat = 30
}
