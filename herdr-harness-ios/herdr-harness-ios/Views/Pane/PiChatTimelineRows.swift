import SwiftUI

/// One lazily laid-out row of the Pi chat timeline.
///
/// The timeline used to mount one `LazyVStack` row per *turn*. An orchestrator
/// turn carries a hundred-plus tool calls, so every streamed token re-laid-out
/// the whole turn (seconds per pass on the main thread), a turn settling
/// re-rendered every turn at once, and the app fell behind the Pi stream until
/// the main thread never returned to the run loop. One row per turn also made
/// the lazy stack lazy in name only: materialising a single child materialised
/// an entire hundred-tool turn. Rows are now one per segment: a streamed token
/// invalidates exactly one row, and the lazy stack only lays out the rows that
/// are on screen.
struct PiTimelineRow: Identifiable, Equatable {
    enum Content: Equatable {
        case user(PiUserMessage)
        case output(PiConversationItem)
        case working(PiWorkingGroup)
        /// The "Pi is starting…" placeholder for an active turn with no items.
        case starting
    }

    /// What the row's slice of the turn rail draws. Turn-level facts are
    /// duplicated into every row so a row can render without its siblings.
    struct Rail: Equatable {
        let hasUser: Bool
        let hasTool: Bool
        let hasFailure: Bool
        let isActive: Bool
        /// First row of the turn: draws the turn's top dot.
        let isFirst: Bool
        /// Last row of the turn: draws the turn's terminal dot.
        let isLast: Bool
    }

    let id: String
    let turnID: String
    let content: Content
    let rail: Rail
    /// First row of a turn that is not the first turn in the timeline: gets
    /// `HerdrProse.turnSpacing` above it instead of the in-turn item spacing.
    let startsTurn: Bool
    /// The very first row: no spacing above it at all.
    let isFirstInTimeline: Bool

    var topSpacing: CGFloat {
        if isFirstInTimeline { return 0 }
        return startsTurn ? HerdrProse.turnSpacing : PiTimelineMetrics.itemSpacing
    }

    func asFirstInTimeline() -> PiTimelineRow {
        PiTimelineRow(
            id: id,
            turnID: turnID,
            content: content,
            rail: rail,
            startsTurn: startsTurn,
            isFirstInTimeline: true
        )
    }

    /// Flattens turns into rows, preserving the reducer's item order. Segments
    /// come from `PiTurnSegmentation` so working groups keep the identity they
    /// had as turn children (expansion state survives the flattening).
    static func rows(for turns: [PiConversationTurn]) -> [PiTimelineRow] {
        var rows: [PiTimelineRow] = []
        rows.reserveCapacity(turns.reduce(0) { $0 + $1.items.count + 2 })
        var isFirstTurn = true

        for turn in turns {
            var contents: [(id: String, content: Content)] = []
            if let user = turn.user {
                contents.append(("\(turn.id)|user", .user(user)))
            }
            for segment in PiTurnSegmentation.segments(for: turn.items) {
                switch segment {
                case let .output(item):
                    contents.append(("\(turn.id)|\(segment.id)", .output(item)))
                case let .working(group):
                    contents.append(("\(turn.id)|\(segment.id)", .working(group)))
                }
            }
            if turn.isActive, turn.items.isEmpty {
                contents.append(("\(turn.id)|starting", .starting))
            }
            guard !contents.isEmpty else { continue }

            let hasTool = turn.items.contains(where: Self.isTool)
            let hasFailure = turn.items.contains(where: Self.isFailed)
            for (index, entry) in contents.enumerated() {
                rows.append(
                    PiTimelineRow(
                        id: entry.id,
                        turnID: turn.id,
                        content: entry.content,
                        rail: Rail(
                            hasUser: turn.user != nil,
                            hasTool: hasTool,
                            hasFailure: hasFailure,
                            isActive: turn.isActive,
                            isFirst: index == 0,
                            isLast: index == contents.count - 1
                        ),
                        startsTurn: index == 0,
                        isFirstInTimeline: isFirstTurn && index == 0
                    )
                )
            }
            isFirstTurn = false
        }
        return rows
    }

    private static func isTool(_ item: PiConversationItem) -> Bool {
        if case .tool = item { return true }
        return false
    }

    private static func isFailed(_ item: PiConversationItem) -> Bool {
        switch item {
        case let .assistant(block):
            if case .failed = block.status { return true }
            return false
        case let .tool(tool):
            return tool.status == .failed
        case let .notice(notice):
            return notice.tone == .error
        case .thinking:
            return false
        }
    }
}

/// The slice of the timeline that is actually mounted. The stack is lazy, so
/// this is not about mounting cost: it bounds the row array that is rebuilt on
/// every stream flush and the identity set `ForEach` has to diff, so a session
/// with thousands of rows does not pay for all of them on every streamed
/// token. The user can ask for the rest. The first mounted row is re-stamped
/// as the first in the timeline so it carries no dangling top spacing.
struct PiTimelineWindow: Equatable {
    static let defaultLimit = 160

    let rows: [PiTimelineRow]
    let hiddenCount: Int

    init(rows: [PiTimelineRow], showsEarlierRows: Bool, limit: Int = PiTimelineWindow.defaultLimit) {
        let hidden = showsEarlierRows ? 0 : max(0, rows.count - max(1, limit))
        guard hidden > 0 else {
            self.rows = rows
            self.hiddenCount = 0
            return
        }
        var visible = Array(rows[hidden...])
        visible[0] = visible[0].asFirstInTimeline()
        self.rows = visible
        self.hiddenCount = hidden
    }
}

enum PiTimelineMetrics {
    static let railWidth: CGFloat = 10
    static let railSpacing: CGFloat = 12
    static let itemSpacing: CGFloat = 13
    static let dotSize: CGFloat = 7
}

/// A single timeline row: its content, offset past the rail, with the rail
/// slice drawn in an overlay so no stack has to negotiate the rail's width.
///
/// `Equatable` on the row model is the whole point: SwiftUI skips the body
/// (and therefore the layout) of every row whose content did not change.
struct PiTimelineRowView: View, Equatable {
    let row: PiTimelineRow

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, PiTimelineMetrics.railWidth + PiTimelineMetrics.railSpacing)
            .padding(.top, row.topSpacing)
            .overlay(alignment: .topLeading) {
                PiTimelineRailSegment(rail: row.rail, topInset: row.topSpacing)
                    .frame(width: PiTimelineMetrics.railWidth)
            }
            .accessibilityIdentifier(accessibilityIdentifier)
    }

    @ViewBuilder
    private var content: some View {
        switch row.content {
        case let .user(message):
            PiUserMessageView(message: message)
        case let .output(item):
            PiConversationItemView(item: item)
        case let .working(group):
            PiWorkingGroupView(group: group)
        case .starting:
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                    .tint(HerdrTheme.mauve)
                Text("Pi is starting…")
                    .font(.callout)
                    .foregroundStyle(HerdrTheme.mist)
            }
        }
    }

    private var accessibilityIdentifier: String {
        switch row.content {
        case .starting: "pi-turn-starting-\(row.turnID)"
        case .user: "pi-turn-\(row.turnID)"
        case .output, .working: "pi-row-\(row.id)"
        }
    }
}

/// The per-row slice of the turn's activity rail: a hairline that runs the
/// full row height (through the spacing above the row, so consecutive rows
/// read as one continuous rail), a top dot on the turn's first row and a
/// terminal dot on its last. Colors mirror the old whole-turn rail.
struct PiTimelineRailSegment: View {
    let rail: PiTimelineRow.Rail
    let topInset: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            if rail.isFirst {
                Color.clear
                    .frame(height: topInset)
                Circle()
                    .fill(rail.hasUser ? HerdrTheme.accent : HerdrTheme.muted)
                    .frame(width: PiTimelineMetrics.dotSize, height: PiTimelineMetrics.dotSize)
            }

            Rectangle()
                .fill(lineGradient)
                .frame(width: 1)
                .frame(maxHeight: .infinity)

            if rail.isLast {
                Circle()
                    .fill(terminalColor)
                    .frame(width: PiTimelineMetrics.dotSize, height: PiTimelineMetrics.dotSize)
            }
        }
        .accessibilityHidden(true)
    }

    private var lineGradient: LinearGradient {
        let colors: [Color]
        if rail.hasTool {
            colors = [HerdrTheme.accent.opacity(0.55), HerdrTheme.mauve.opacity(0.7), HerdrTheme.signal.opacity(0.62)]
        } else {
            colors = [HerdrTheme.accent.opacity(0.48), HerdrTheme.mauve.opacity(0.4), HerdrTheme.success.opacity(0.52)]
        }
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    private var terminalColor: Color {
        if rail.hasFailure { return HerdrTheme.alert }
        return rail.isActive ? HerdrTheme.working : HerdrTheme.success
    }
}
