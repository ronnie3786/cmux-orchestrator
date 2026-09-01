import CoreGraphics
import Testing
@testable import herdr_harness_mac

@Suite("Herdr HUD placement")
struct HerdrHudPlacementTests {
    @Test("Default inset is the compact eight-point corner offset")
    func defaultInsetIsEightPoints() {
        #expect(HerdrHudPlacement.defaultInset == 8)
    }

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

    @Test("Collapsed content keeps its original size with no session chips")
    func collapsedContentSizeWithoutChipsMatchesOriginal() {
        #expect(HerdrHudPlacement.collapsedContentSize(chipCount: 0) == HerdrHudPlacement.collapsedSize)
    }

    @Test("Collapsed HUD width grows by one fixed slot per visible chip")
    func collapsedContentSizeGrowsByChipSlots() {
        for count in 1...HerdrHudPlacement.maxChips {
            let size = HerdrHudPlacement.collapsedContentSize(chipCount: count)
            #expect(
                size.width == HerdrHudPlacement.collapsedSize.width
                    + CGFloat(count) * (HerdrHudPlacement.chipWidth + HerdrHudPlacement.chipSpacing)
            )
            #expect(size.height == HerdrHudPlacement.collapsedSize.height)
        }
    }

    @Test("Session chips keep the collapsed top-right anchor fixed")
    func chipsKeepTopRightAnchorFixed() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let offset = CGSize(width: 24, height: 32)
        let withoutChips = HerdrHudPlacement.frame(
            isExpanded: false,
            visibleFrame: visibleFrame,
            topRightOffset: offset
        )
        let withChips = HerdrHudPlacement.frame(
            isExpanded: false,
            visibleFrame: visibleFrame,
            topRightOffset: offset,
            chipCount: 3
        )

        #expect(withChips.maxX == withoutChips.maxX)
        #expect(withChips.maxY == withoutChips.maxY)
    }

    @Test("Expanded geometry ignores the collapsed session chip count")
    func expandedGeometryIgnoresChipCount() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let offset = HerdrHudPlacement.defaultOffset()
        let withoutChips = HerdrHudPlacement.frame(
            isExpanded: true,
            visibleFrame: visibleFrame,
            topRightOffset: offset
        )
        let withChips = HerdrHudPlacement.frame(
            isExpanded: true,
            visibleFrame: visibleFrame,
            topRightOffset: offset,
            chipCount: 3
        )

        #expect(withChips == withoutChips)
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

    @Test("A wide chip strip still clamps inside a constrained display")
    func wideChipStripClampsInsideVisibleFrame() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 500, height: 400)
        let frame = HerdrHudPlacement.frame(
            isExpanded: false,
            visibleFrame: visibleFrame,
            topRightOffset: CGSize(width: 10_000, height: -10_000),
            chipCount: 3
        )

        #expect(frame.minX >= visibleFrame.minX)
        #expect(frame.maxX <= visibleFrame.maxX)
        #expect(frame.minY >= visibleFrame.minY)
        #expect(frame.maxY <= visibleFrame.maxY)
    }

    private func paddedSize(for contentSize: CGSize) -> CGSize {
        CGSize(
            width: contentSize.width + HerdrHudPlacement.shadowMargin * 2,
            height: contentSize.height + HerdrHudPlacement.shadowMargin * 2
        )
    }
}
