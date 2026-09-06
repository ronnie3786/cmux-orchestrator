import CoreGraphics

/// Pure panel-placement math. Offsets are deliberately monitor-relative so a
/// HUD keeps a sensible position when displays or resolutions change.
struct HerdrHudPlacement: Equatable, Sendable {
    var topRightOffset: CGSize

    static let defaultInset: CGFloat = 8
    static let collapsedSize = CGSize(width: 72, height: 72)
    static let expandedSize = CGSize(width: 420, height: 580)
    static let shadowMargin: CGFloat = 40
    static let chipWidth: CGFloat = 166.6
    /// The chip's rendered height AND the height the panel frame reserves for
    /// it — `HerdrHudSessionChipsView` must read this, not `HerdrTheme`, or the
    /// two disagree and the collapsed panel mis-sizes. Deliberately larger than
    /// `HerdrTheme.minHitTarget`; a literal because this type is pure
    /// CoreGraphics math with no SwiftUI dependency.
    static let chipHeight: CGFloat = 42
    static let chipSpacing: CGFloat = 6
    /// A fixed accessory lane keeps result-node hover expansion inside the
    /// panel's bounds. The lane projects left from the session identity, so
    /// the HUD's top-right anchor remains visually immovable.
    static let resultRailWidth: CGFloat = 224
    static let resultNodeSize: CGFloat = 30
    static let resultNodeSpacing: CGFloat = 5
    static let resultConnectorWidth: CGFloat = 13
    static let resultNodeExpandedWidth: CGFloat = 136
    static let maxVisibleResults = 3
    /// How many session chips the collapsed HUD groups down to. The rest are
    /// summarised by the `+N` control, which reveals them up to
    /// `maxExpandedChips`.
    static let maxChips = 3
    static let maxExpandedChips = 12
    /// A fully revealed stack may still need one final `+N` row when more than
    /// `maxExpandedChips` sessions exist.
    static let maxCollapsedRows = maxExpandedChips + 1
    enum NotesLayout: Equatable, Sendable { case hidden, compact(count: Int), rows(count: Int), card }
    static let notesGap: CGFloat = 10
    static let notesWidth: CGFloat = 236
    static let noteRowHeight: CGFloat = 40
    static let noteRowSpacing: CGFloat = 6
    static let noteCtaHeight: CGFloat = 30
    /// Tall enough for one line of the note's title — the collapsed stack names
    /// its notes rather than showing anonymous color bars.
    static let noteCompactBarHeight: CGFloat = 22
    static let noteCompactWidth: CGFloat = 158
    static let noteCompactBarSpacing: CGFloat = 4
    static let maxCompactNotes = 5
    static let maxNoteRows = 6
    static let maxNoteRowsWhenExpanded = 3
    static let noteCardSize = CGSize(width: 320, height: 360)
    /// The reply composer is its own small surface beside the orb rather than a
    /// row inside the chat, so a spoken reply never looks like a HUD prompt.
    static let voiceReplyCardSize = CGSize(width: 300, height: 168)
    static let quickVoiceCardSize = CGSize(width: 336, height: 320)

    static func maxNoteRows(isExpanded: Bool) -> Int { isExpanded ? maxNoteRowsWhenExpanded : maxNoteRows }
    static func notesContentSize(_ layout: NotesLayout, isExpanded: Bool) -> CGSize {
        switch layout {
        case .hidden:
            return .zero
        case let .compact(count):
            let k = min(max(count, 0), maxCompactNotes)
            guard k > 0 else { return .zero }
            return CGSize(width: noteCompactWidth, height: CGFloat(k) * noteCompactBarHeight + CGFloat(k - 1) * noteCompactBarSpacing)
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

    static func collapsedContentSize(
        chipCount: Int,
        hasResultRail: Bool = false
    ) -> CGSize {
        let count = min(max(0, chipCount), maxCollapsedRows)
        let baseSize = if count > 0 {
            CGSize(
                width: max(collapsedSize.width, chipWidth),
                height: collapsedSize.height + CGFloat(count) * (chipHeight + chipSpacing)
            )
        } else {
            collapsedSize
        }
        return CGSize(
            width: baseSize.width + (hasResultRail ? resultRailWidth : 0),
            height: baseSize.height
        )
    }

    static func frame(
        isExpanded: Bool,
        visibleFrame: CGRect,
        topRightOffset: CGSize,
        chipCount: Int = 0,
        hasResultRail: Bool = false,
        notesSize: CGSize = .zero,
        voiceReplySize: CGSize = .zero,
        quickVoiceSize: CGSize = .zero
    ) -> CGRect {
        var contentSize = isExpanded
            ? expandedSize
            : collapsedContentSize(chipCount: chipCount, hasResultRail: hasResultRail)
        if quickVoiceSize.height > 0 {
            contentSize.width = max(contentSize.width, quickVoiceSize.width)
            contentSize.height += chipSpacing + quickVoiceSize.height
        }
        if voiceReplySize.height > 0 {
            contentSize.width = max(contentSize.width, voiceReplySize.width)
            contentSize.height += notesGap + voiceReplySize.height
        }
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
        let x = min(max(desiredX, visibleFrame.minX - shadowMargin), visibleFrame.maxX - size.width + shadowMargin)
        let y = min(max(desiredY, visibleFrame.minY - shadowMargin), visibleFrame.maxY - size.height + shadowMargin)
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
