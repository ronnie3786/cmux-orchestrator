import CoreGraphics

/// Pure panel-placement math. Offsets are deliberately monitor-relative so a
/// HUD keeps a sensible position when displays or resolutions change.
struct HerdrHudPlacement: Equatable, Sendable {
    var topRightOffset: CGSize

    static let defaultInset: CGFloat = 8
    static let collapsedSize = CGSize(width: 72, height: 72)
    static let expandedSize = CGSize(width: 420, height: 580)
    static let shadowMargin: CGFloat = 40
    static let chipWidth: CGFloat = 132
    static let chipSpacing: CGFloat = 6
    static let maxChips = 3

    static func defaultOffset() -> CGSize {
        CGSize(width: defaultInset, height: defaultInset)
    }

    static func collapsedContentSize(chipCount: Int) -> CGSize {
        let count = min(max(0, chipCount), maxChips)
        guard count > 0 else { return collapsedSize }
        return CGSize(
            width: collapsedSize.width + CGFloat(count) * (chipWidth + chipSpacing),
            height: collapsedSize.height
        )
    }

    static func frame(
        isExpanded: Bool,
        visibleFrame: CGRect,
        topRightOffset: CGSize,
        chipCount: Int = 0
    ) -> CGRect {
        let contentSize = isExpanded ? expandedSize : collapsedContentSize(chipCount: chipCount)
        let preferredSize = CGSize(
            width: contentSize.width + shadowMargin * 2,
            height: contentSize.height + shadowMargin * 2
        )
        // A visible frame smaller than the HUD is unusual, but this keeps the
        // contract true even on extremely constrained displays.
        let size = CGSize(
            width: min(preferredSize.width, visibleFrame.width),
            height: min(preferredSize.height, visibleFrame.height)
        )
        let desiredX = visibleFrame.maxX - topRightOffset.width - size.width
        let desiredY = visibleFrame.maxY - topRightOffset.height - size.height
        let x = min(max(desiredX, visibleFrame.minX), visibleFrame.maxX - size.width)
        let y = min(max(desiredY, visibleFrame.minY), visibleFrame.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    static func offset(forFrame frame: CGRect, visibleFrame: CGRect) -> CGSize {
        CGSize(
            width: visibleFrame.maxX - frame.maxX,
            height: visibleFrame.maxY - frame.maxY
        )
    }

    static func reclamp(
        topRightOffset: CGSize,
        isExpanded: Bool,
        visibleFrame: CGRect
    ) -> CGSize {
        let clampedFrame = frame(
            isExpanded: isExpanded,
            visibleFrame: visibleFrame,
            topRightOffset: topRightOffset
        )
        return offset(forFrame: clampedFrame, visibleFrame: visibleFrame)
    }
}
