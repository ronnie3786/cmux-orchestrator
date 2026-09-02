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
    /// Mirrors `HerdrTheme.minHitTarget`. Duplicated as a literal because this
    /// type is deliberately pure CoreGraphics math with no SwiftUI dependency.
    static let chipHeight: CGFloat = 28
    static let chipSpacing: CGFloat = 6
    /// How many session chips the collapsed HUD groups down to. The rest are
    /// summarised by the `+N` control, which reveals them up to
    /// `maxExpandedChips`.
    static let maxChips = 3
    static let maxExpandedChips = 12
    enum NotesLayout: Equatable, Sendable { case hidden, compact(count: Int), rows(count: Int), card }
    static let notesGap: CGFloat = 10
    static let notesWidth: CGFloat = 236
    static let noteRowHeight: CGFloat = 30
    static let noteRowSpacing: CGFloat = 6
    static let noteCtaHeight: CGFloat = 30
    /// Tall enough for one line of the note's title — the collapsed stack names
    /// its notes rather than showing anonymous color bars.
    static let noteCompactBarHeight: CGFloat = 22
    static let noteCompactBarSpacing: CGFloat = 4
    static let maxCompactNotes = 5
    static let maxNoteRows = 6
    static let maxNoteRowsWhenExpanded = 3
    static let noteCardSize = CGSize(width: 320, height: 360)

    static func maxNoteRows(isExpanded: Bool) -> Int { isExpanded ? maxNoteRowsWhenExpanded : maxNoteRows }
    static func notesContentSize(_ layout: NotesLayout, isExpanded: Bool) -> CGSize {
        switch layout {
        case .hidden:
            return .zero
        case let .compact(count):
            let k = min(max(count, 0), maxCompactNotes)
            guard k > 0 else { return .zero }
            return CGSize(width: chipWidth, height: CGFloat(k) * noteCompactBarHeight + CGFloat(k - 1) * noteCompactBarSpacing)
        case let .rows(count):
            let k = min(max(count, 0), maxNoteRows(isExpanded: isExpanded))
            return CGSize(width: notesWidth, height: noteCtaHeight + CGFloat(k) * (noteRowHeight + noteRowSpacing))
        case .card:
            return noteCardSize
        }
    }

    static func defaultOffset() -> CGSize {
        CGSize(width: defaultInset, height: defaultInset)
    }

    static func collapsedContentSize(chipCount: Int) -> CGSize {
        let count = min(max(0, chipCount), maxExpandedChips)
        guard count > 0 else { return collapsedSize }
        return CGSize(
            width: max(collapsedSize.width, chipWidth),
            height: collapsedSize.height + CGFloat(count) * (chipHeight + chipSpacing)
        )
    }

    static func frame(
        isExpanded: Bool,
        visibleFrame: CGRect,
        topRightOffset: CGSize,
        chipCount: Int = 0,
        notesSize: CGSize = .zero
    ) -> CGRect {
        var contentSize = isExpanded ? expandedSize : collapsedContentSize(chipCount: chipCount)
        if notesSize.height > 0 {
            let availableContentHeight = max(0, visibleFrame.height - shadowMargin * 2)
            let excess = max(0, contentSize.height + notesGap + notesSize.height - availableContentHeight)
            let shrunkNotesHeight = max(noteCtaHeight, notesSize.height - excess)
            contentSize.width = max(contentSize.width, notesSize.width)
            contentSize.height += notesGap + shrunkNotesHeight
        }
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
