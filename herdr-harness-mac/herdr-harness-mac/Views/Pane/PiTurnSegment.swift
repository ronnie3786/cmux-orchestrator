/// Presentation-only partition of a turn's items into visible output and
/// collapsed runs of sub-process activity. Purely derived from `turn.items`,
/// the reducer's item order and indices are untouched, so this can never drop
/// or reorder content.
struct PiWorkingGroup: Identifiable, Equatable {
    let id: String
    let items: [PiConversationItem]
    let toolCount: Int
    let thinkingCount: Int
    /// Title of the most recent tool in the group, via `PiToolPresentation`
    /// (e.g. "Command", "Read"). `nil` when the group is thinking-only.
    let latestToolTitle: String?
    /// Any thinking block still streaming, or any tool still waiting/running.
    let isLive: Bool
    let failureCount: Int

    var stepCount: Int { toolCount + thinkingCount }
    var hasFailure: Bool { failureCount > 0 }
}

enum PiTurnSegment: Identifiable, Equatable {
    case output(PiConversationItem)
    case working(PiWorkingGroup)

    var id: String {
        switch self {
        case let .output(item): "output:\(item.id)"
        case let .working(group): group.id
        }
    }
}

enum PiTurnSegmentation {
    /// Collapses each *contiguous* run of working items into one group,
    /// preserving chronological order relative to output messages.
    static func segments(for items: [PiConversationItem]) -> [PiTurnSegment] {
        var segments: [PiTurnSegment] = []
        segments.reserveCapacity(items.count)
        var pending: [PiConversationItem] = []

        func flush() {
            guard !pending.isEmpty else { return }
            segments.append(.working(group(pending)))
            pending.removeAll(keepingCapacity: true)
        }

        for item in items {
            if item.isWorking {
                pending.append(item)
            } else {
                flush()
                segments.append(.output(item))
            }
        }
        flush()
        return segments
    }

    private static func group(_ items: [PiConversationItem]) -> PiWorkingGroup {
        var toolCount = 0
        var thinkingCount = 0
        var latestToolTitle: String?
        var isLive = false
        var failureCount = 0
        for item in items {
            switch item {
            case let .tool(tool):
                toolCount += 1
                latestToolTitle = PiToolPresentation(tool: tool).title
                if tool.status == .waiting || tool.status == .running { isLive = true }
                if tool.status == .failed { failureCount += 1 }
            case let .thinking(block):
                thinkingCount += 1
                if block.isStreaming { isLive = true }
            case .assistant, .notice:
                continue
            }
        }
        // The FIRST item's id, never the last and never a content hash: a tool
        // appended to a live group must not change the group's identity, or
        // SwiftUI tears the view down and the user's expansion state, and the
        // insertion animation — resets mid-run.
        return PiWorkingGroup(
            id: "working:\(items.first?.id ?? "empty")",
            items: items,
            toolCount: toolCount,
            thinkingCount: thinkingCount,
            latestToolTitle: latestToolTitle,
            isLive: isLive,
            failureCount: failureCount
        )
    }
}
