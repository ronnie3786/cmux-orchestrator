import CoreGraphics
import Testing
@testable import herdr_harness_mac

@Suite("Herdr HUD placement")
struct HerdrHudPlacementTests {
    // MARK: - Frame placement

    @Test("Default offset places the collapsed HUD inside the top-right inset")
    func defaultOffsetPlacesCollapsedHudAtTopRight() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let frame = HerdrHudPlacement.frame(
            isExpanded: false,
            visibleFrame: visibleFrame,
            topRightOffset: HerdrHudPlacement.defaultOffset()
        )

        #expect(frame.size == paddedSize(for: HerdrHudPlacement.collapsedSize))
        #expect(frame.origin.x == visibleFrame.maxX - HerdrHudPlacement.defaultInset - frame.width)
        #expect(frame.origin.y == visibleFrame.maxY - HerdrHudPlacement.defaultInset - frame.height)
    }

    @Test("Extreme offsets keep the HUD fully inside its visible frame")
    func extremeOffsetsAreClampedToVisibleFrame() {
        let visibleFrame = CGRect(x: 100, y: 200, width: 300, height: 250)
        let frame = HerdrHudPlacement.frame(
            isExpanded: true,
            visibleFrame: visibleFrame,
            topRightOffset: CGSize(width: 10_000, height: -10_000)
        )

        #expect(frame.minX >= visibleFrame.minX)
        #expect(frame.maxX <= visibleFrame.maxX)
        #expect(frame.minY >= visibleFrame.minY)
        #expect(frame.maxY <= visibleFrame.maxY)
    }

    @Test("Expanding retains the HUD top-right anchor")
    func expandingKeepsTopRightAnchorFixed() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let offset = CGSize(width: 24, height: 32)
        let collapsed = HerdrHudPlacement.frame(
            isExpanded: false,
            visibleFrame: visibleFrame,
            topRightOffset: offset
        )
        let expanded = HerdrHudPlacement.frame(
            isExpanded: true,
            visibleFrame: visibleFrame,
            topRightOffset: offset
        )

        #expect(collapsed.maxX == expanded.maxX)
        #expect(collapsed.maxY == expanded.maxY)
        #expect(collapsed.size != expanded.size)
    }

    @Test("Panel frames include transparent room for HUD shadows")
    func frameAddsShadowMarginAroundVisibleContent() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let collapsed = HerdrHudPlacement.frame(
            isExpanded: false,
            visibleFrame: visibleFrame,
            topRightOffset: HerdrHudPlacement.defaultOffset()
        )
        let expanded = HerdrHudPlacement.frame(
            isExpanded: true,
            visibleFrame: visibleFrame,
            topRightOffset: HerdrHudPlacement.defaultOffset()
        )

        #expect(collapsed.size == paddedSize(for: HerdrHudPlacement.collapsedSize))
        #expect(expanded.size == paddedSize(for: HerdrHudPlacement.expandedSize))
    }

    // MARK: - Offset persistence

    @Test("Frame anchor offsets round-trip through collapsed placement")
    func anchorOffsetsRoundTrip() {
        let visibleFrame = CGRect(x: 10, y: 20, width: 1_600, height: 900)
        let original = CGRect(
            x: 1_430,
            y: 740,
            width: paddedSize(for: HerdrHudPlacement.collapsedSize).width,
            height: paddedSize(for: HerdrHudPlacement.collapsedSize).height
        )
        let offset = HerdrHudPlacement.offset(forFrame: original, visibleFrame: visibleFrame)
        let roundTripped = HerdrHudPlacement.frame(
            isExpanded: false,
            visibleFrame: visibleFrame,
            topRightOffset: offset
        )

        #expect(roundTripped == original)
    }

    @Test("Reclamping an old anchor fits a smaller visible frame")
    func reclampingAfterScreenShrinkFitsSmallerVisibleFrame() {
        let largeFrame = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let smallFrame = CGRect(x: 0, y: 0, width: 500, height: 400)
        let oldOffset = HerdrHudPlacement.offset(
            forFrame: CGRect(
                x: 1_700,
                y: 900,
                width: paddedSize(for: HerdrHudPlacement.collapsedSize).width,
                height: paddedSize(for: HerdrHudPlacement.collapsedSize).height
            ),
            visibleFrame: largeFrame
        )
        let reclamped = HerdrHudPlacement.reclamp(
            topRightOffset: oldOffset,
            isExpanded: false,
            visibleFrame: smallFrame
        )
        let frame = HerdrHudPlacement.frame(
            isExpanded: false,
            visibleFrame: smallFrame,
            topRightOffset: reclamped
        )

        #expect(frame.minX >= smallFrame.minX)
        #expect(frame.maxX <= smallFrame.maxX)
        #expect(frame.minY >= smallFrame.minY)
        #expect(frame.maxY <= smallFrame.maxY)
    }

    private func paddedSize(for contentSize: CGSize) -> CGSize {
        CGSize(
            width: contentSize.width + HerdrHudPlacement.shadowMargin * 2,
            height: contentSize.height + HerdrHudPlacement.shadowMargin * 2
        )
    }
}
