import CoreFoundation
import Testing
@testable import herdr_harness_mac

@Suite("Sidebar metrics")
struct SidebarMetricsTests {
    @Test("Typography and icons use the old-to-enlarged midpoint")
    func typographyMidpoints() {
        #expect(SidebarMetrics.projectLabelSize == 13.5)
        #expect(SidebarMetrics.tabLabelSize == 12.5)
        #expect(SidebarMetrics.chatLabelSize == 13.5)
        #expect(SidebarMetrics.hierarchyIconSize == 11.5)
    }

    @Test("Row heights use the old-to-enlarged midpoint")
    func rowHeightMidpoints() {
        #expect(SidebarMetrics.projectRowHeight == 34)
        #expect(SidebarMetrics.tabRowHeight == 30)
        #expect(SidebarMetrics.chatRowHeight == 30)
    }
}
