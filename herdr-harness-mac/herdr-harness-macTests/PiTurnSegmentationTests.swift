import Testing
@testable import herdr_harness_mac

@Suite("Pi turn segmentation")
struct PiTurnSegmentationTests {
    @Test("All output items remain visible and ordered")
    func allOutputItemsRemainOutputSegments() {
        let items = [assistant("assistant:1"), notice("notice:1", tone: .neutral), assistant("assistant:2")]

        let segments = PiTurnSegmentation.segments(for: items)

        #expect(segments.map(\.id) == ["output:assistant:1", "output:notice:1", "output:assistant:2"])
    }

    @Test("A contiguous working run forms one group")
    func contiguousWorkingItemsFormOneGroup() {
        let segments = PiTurnSegmentation.segments(for: [thinking("thinking:1"), tool("tool:1"), tool("tool:2")])

        guard case let .working(group) = segments.first else {
            Issue.record("Expected one working group")
            return
        }
        #expect(segments.count == 1)
        #expect(group.stepCount == 3)
        #expect(group.toolCount == 2)
        #expect(group.thinkingCount == 1)
    }

    @Test("Working groups preserve their position between output messages")
    func workingGroupsPreserveChronologicalOrder() {
        let items = [
            thinking("thinking:1"),
            assistant("assistant:1"),
            tool("tool:1"),
            tool("tool:2"),
            assistant("assistant:2")
        ]

        let segments = PiTurnSegmentation.segments(for: items)

        #expect(segments.map(\.id) == ["working:thinking:1", "output:assistant:1", "working:tool:1", "output:assistant:2"])
    }

    @Test("Segmentation never drops an item")
    func segmentationNeverDropsItems() {
        let items = [
            thinking("thinking:1"),
            tool("tool:1"),
            assistant("assistant:1"),
            notice("notice:1", tone: .warning),
            tool("tool:2")
        ]

        let flattened = PiTurnSegmentation.segments(for: items).flatMap { segment in
            switch segment {
            case let .output(item): [item]
            case let .working(group): group.items
            }
        }

        #expect(flattened.map(\.id) == items.map(\.id))
    }

    @Test("A working group's identity stays stable when tools append")
    func workingGroupIdentityStaysStableWhenToolsAppend() {
        let initial = PiTurnSegmentation.segments(for: [thinking("thinking:1"), tool("tool:1")])
        let appended = PiTurnSegmentation.segments(for: [thinking("thinking:1"), tool("tool:1"), tool("tool:2")])

        guard case let .working(initialGroup) = initial.first,
              case let .working(appendedGroup) = appended.first else {
            Issue.record("Expected working groups")
            return
        }
        #expect(initialGroup.id == appendedGroup.id)
    }

    @Test("Live state follows pending tools and streaming thinking")
    func liveStateFollowsWorkingItemState() {
        #expect(workingGroup([tool("tool:waiting", status: .waiting)]).isLive)
        #expect(workingGroup([tool("tool:running", status: .running)]).isLive)
        #expect(workingGroup([thinking("thinking:streaming", isStreaming: true)]).isLive)
        #expect(!workingGroup([thinking("thinking:settled"), tool("tool:succeeded", status: .succeeded)]).isLive)
    }

    @Test("Failed tools are counted and surfaced")
    func failedToolsAreCounted() {
        let group = workingGroup([tool("tool:1", status: .failed), tool("tool:2", status: .failed), tool("tool:3", status: .succeeded)])

        #expect(group.failureCount == 2)
        #expect(group.hasFailure)
    }

    @Test("The latest tool supplies the group title")
    func latestToolSuppliesGroupTitle() {
        let tools = workingGroup([thinking("thinking:1"), tool("tool:read", name: "read"), tool("tool:command", name: "bash")])
        let thinkingOnly = workingGroup([thinking("thinking:2")])

        #expect(tools.latestToolTitle == "Command")
        #expect(thinkingOnly.latestToolTitle == nil)
    }

    @Test("Only thinking and tool items are working activity")
    func itemWorkingClassification() {
        #expect(thinking("thinking:1").isWorking)
        #expect(tool("tool:1").isWorking)
        #expect(!assistant("assistant:complete").isWorking)
        #expect(!assistant("assistant:failed", status: .failed("Provider unavailable")).isWorking)
        for tone in [PiConversationNotice.Tone.neutral, .warning, .error] {
            #expect(!notice("notice:\(tone)", tone: tone).isWorking)
        }
    }

    private func workingGroup(_ items: [PiConversationItem]) -> PiWorkingGroup {
        let segments = PiTurnSegmentation.segments(for: items)
        guard case let .working(group) = segments.first else {
            fatalError("Expected working items to form a group")
        }
        return group
    }

    private func assistant(_ id: String, status: PiAssistantBlock.Status = .complete) -> PiConversationItem {
        .assistant(PiAssistantBlock(id: id, text: "Output", status: status, timestamp: nil))
    }

    private func thinking(_ id: String, isStreaming: Bool = false) -> PiConversationItem {
        .thinking(PiThinkingBlock(id: id, text: "Thinking", isStreaming: isStreaming, isRedacted: false, startedAt: nil))
    }

    private func tool(
        _ id: String,
        name: String = "read",
        status: PiToolInvocation.Status = .succeeded
    ) -> PiConversationItem {
        .tool(PiToolInvocation(id: id, callID: "call:\(id)", name: name, arguments: nil, result: nil, status: status, startedAt: nil, finishedAt: nil))
    }

    private func notice(_ id: String, tone: PiConversationNotice.Tone) -> PiConversationItem {
        .notice(PiConversationNotice(id: id, title: "Notice", detail: nil, tone: tone, timestamp: nil))
    }
}
