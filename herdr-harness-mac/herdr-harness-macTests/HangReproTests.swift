import AppKit
import Foundation
import os
import SwiftUI
import Testing
@testable import herdr_harness_mac

/// Opt-in layout-cost probe for the chat timeline, built while chasing the
/// 2026-09 work-Mac freeze. It loads real Pi snapshots from the sandbox
/// container's `tmp/herdr-fixtures/` (see `HerdrPiReplay` for the fixture
/// format) through the real reducer and lays the real timeline out in an
/// offscreen window, printing per-turn timings as `HANGREPRO` lines. Every
/// test returns early when the fixtures are absent, so the suite is a no-op
/// on CI and on a fresh checkout. A hang here hangs the test host, which can
/// then be `sample`d with debug symbols.
@Suite("Hang repro", .serialized)
@MainActor
struct HangReproTests {
    nonisolated static let fixtureDirectory = FileManager.default.temporaryDirectory
        .appending(path: "herdr-fixtures", directoryHint: .isDirectory)

    nonisolated static let fixtures = [
        "vault_old.json",
        "vault_old_streaming.json",
        "vault_new.json",
        "bench_live.json",
        "doxclaude.json",
        "bench_full.json",
    ]

    @Test("Timeline layout time per fixture", arguments: fixtures)
    func timelineLayout(fixture: String) async throws {
        guard Self.hasFixture(fixture) else { return }
        let (store, task) = try await Self.loadStore(fixture: fixture)
        defer { task.cancel() }

        let clock = ContinuousClock()
        var perTurn: [(String, Duration)] = []
        for (index, turn) in store.turns.enumerated() {
            let rows = PiTimelineRow.rows(for: [turn])
            let start = clock.now
            _ = try await HerdrRenderHarness.render(
                "hang-\(fixture)-turn\(index).png",
                size: CGSize(width: 980, height: 760),
                settlePasses: 2
            ) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            PiTimelineRowView(row: row).equatable()
                        }
                    }
                    .padding(16)
                }
            }
            perTurn.append((turn.id, start.duration(to: clock.now)))
        }
        for (id, duration) in perTurn.sorted(by: { $0.1 > $1.1 }).prefix(8) {
            print("HANGREPRO fixture=\(fixture) turn=\(id) elapsed=\(duration)")
        }

        let start = clock.now
        let result = try await HerdrRenderHarness.render(
            "hang-\(fixture)-timeline.png",
            size: CGSize(width: 980, height: 760),
            settlePasses: 8
        ) {
            PiChatTimelineView(store: store, isConnected: true) { _, _ in true }
        }
        let elapsed = start.duration(to: clock.now)
        print("HANGREPRO fixture=\(fixture) turns=\(store.turns.count) timelineElapsed=\(elapsed)")
        result.expectSubstantial()
    }


    @Test("Per-item layout cost for the slowest turns")
    func perItemLayout() async throws {
        let targets: [(String, String)] = [
            ("doxclaude.json", "turn:bf7c3f80"),
            ("bench_full.json", "turn:20f9e71f"),
        ]
        let clock = ContinuousClock()
        for (fixture, turnID) in targets {
            guard Self.hasFixture(fixture) else { continue }
            let (store, task) = try await Self.loadStore(fixture: fixture)
            defer { task.cancel() }
            guard let turn = store.turns.first(where: { $0.id == turnID }) else {
                Issue.record("turn \(turnID) missing in \(fixture)")
                continue
            }
            let segments = PiTurnSegmentation.segments(for: turn.items)
            print("HANGREPRO item-bench fixture=\(fixture) turn=\(turnID) items=\(turn.items.count) segments=\(segments.count)")
            for (index, segment) in segments.enumerated() {
                let start = clock.now
                _ = try await HerdrRenderHarness.render(
                    "bench-\(fixture)-seg\(index).png",
                    size: CGSize(width: 980, height: 760),
                    settlePasses: 1
                ) {
                    ScrollView {
                        Group {
                            switch segment {
                            case let .output(item):
                                PiConversationItemView(item: item)
                            case let .working(group):
                                PiWorkingGroupView(group: group)
                            }
                        }
                        .padding(16)
                    }
                }
                let elapsed = start.duration(to: clock.now)
                var detail = ""
                switch segment {
                case let .output(item):
                    switch item {
                    case let .assistant(block):
                        let blocks = PiMarkdownParser.parse(block.text)
                        var kinds: [String: Int] = [:]
                        var listItems = 0
                        var tableCells = 0
                        for b in blocks {
                            switch b {
                            case .paragraph: kinds["p", default: 0] += 1
                            case .heading: kinds["h", default: 0] += 1
                            case .code: kinds["code", default: 0] += 1
                            case let .list(_, items): kinds["list", default: 0] += 1; listItems += items.count
                            case .quote: kinds["quote", default: 0] += 1
                            case let .table(_, t): kinds["table", default: 0] += 1; tableCells += (t.rows.count + 1) * t.headers.count
                            case .thematicBreak: kinds["hr", default: 0] += 1
                            }
                        }
                        detail = "assistant chars=\(block.text.count) blocks=\(blocks.count) \(kinds) listItems=\(listItems) tableCells=\(tableCells)"
                    case let .thinking(b): detail = "thinking chars=\(b.text.count)"
                    case let .tool(t): detail = "tool \(t.name)"
                    case .notice: detail = "notice"
                    }
                case let .working(group):
                    detail = "working group tools=\(group.toolCount) thinking=\(group.thinkingCount) failed=\(group.failureCount)"
                }
                print("HANGREPRO item-bench seg=\(index) elapsed=\(elapsed) \(detail)")

                // Variants for assistant markdown: isolate selection + nesting cost.
                if case let .output(.assistant(block)) = segment, block.text.count > 500 {
                    let blocks = PiMarkdownParser.parse(block.text)
                    let v1 = clock.now
                    _ = try await HerdrRenderHarness.render("bench-v1.png", size: CGSize(width: 980, height: 760), settlePasses: 1) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(blocks) { b in
                                    switch b {
                                    case let .paragraph(_, text), let .heading(_, _, text), let .quote(_, text):
                                        Text(PiMarkdownInlineCache.render(text))
                                    case let .code(_, _, code):
                                        Text(code)
                                    case let .list(_, items):
                                        VStack(alignment: .leading, spacing: 6) {
                                            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                                                HStack(alignment: .top, spacing: 8) {
                                                    Text("•").frame(width: 24, alignment: .trailing)
                                                    Text(PiMarkdownInlineCache.render(item.text)).frame(maxWidth: .infinity, alignment: .leading)
                                                }
                                                .padding(.leading, CGFloat(min(item.depth, 6)) * 17)
                                            }
                                        }
                                    case let .table(_, t):
                                        Text("table \(t.rows.count)x\(t.headers.count)")
                                    case .thematicBreak:
                                        Divider()
                                    }
                                }
                            }
                            .padding(16)
                        }
                    }
                    print("HANGREPRO item-bench seg=\(index) variant=noSelectionSameNesting elapsed=\(v1.duration(to: clock.now))")

                    let v2 = clock.now
                    _ = try await HerdrRenderHarness.render("bench-v2.png", size: CGSize(width: 980, height: 760), settlePasses: 1) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(blocks) { b in
                                    switch b {
                                    case let .paragraph(_, text), let .heading(_, _, text), let .quote(_, text):
                                        Text(PiMarkdownInlineCache.render(text)).textSelection(.enabled)
                                    case let .code(_, _, code):
                                        Text(code).textSelection(.enabled)
                                    case let .list(_, items):
                                        VStack(alignment: .leading, spacing: 6) {
                                            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                                                HStack(alignment: .top, spacing: 8) {
                                                    Text("•").frame(width: 24, alignment: .trailing)
                                                    Text(PiMarkdownInlineCache.render(item.text)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                                }
                                                .padding(.leading, CGFloat(min(item.depth, 6)) * 17)
                                            }
                                        }
                                    case let .table(_, t):
                                        Text("table \(t.rows.count)x\(t.headers.count)")
                                    case .thematicBreak:
                                        Divider()
                                    }
                                }
                            }
                            .padding(16)
                        }
                    }
                    print("HANGREPRO item-bench seg=\(index) variant=selectionSameNesting elapsed=\(v2.duration(to: clock.now))")

                    let v3 = clock.now
                    _ = try await HerdrRenderHarness.render("bench-v3.png", size: CGSize(width: 980, height: 760), settlePasses: 1) {
                        ScrollView {
                            Text(PiMarkdownInlineCache.render(block.text)).textSelection(.enabled).padding(16)
                        }
                    }
                    print("HANGREPRO item-bench seg=\(index) variant=singleSelectableText elapsed=\(v3.duration(to: clock.now))")
                }
            }
        }
    }

    @Test("Streaming turn start into a mounted chat surface")
    func streamingTurnStart() async throws {
        let fixture = "doxclaude.json"
        guard Self.hasFixture(fixture) else { return }
        let url = Self.fixtureDirectory.appending(path: fixture)
        let snapshot = try JSONDecoder().decode(PiConversationSnapshot.self, from: Data(contentsOf: url))
        let store = PiConversationStore()
        store.snapshotProvider = { _ in snapshot }
        store.eventsProvider = { _, _ in
            AsyncThrowingStream { continuation in
                Task.detached {
                    var cursor = 5000
                    func send(_ json: String) {
                        cursor += 1
                        if let event = try? Self.streamEvent(cursor, json) {
                            continuation.yield(event)
                        } else {
                            print("HANGREPRO bad event json: \(json.prefix(80))")
                        }
                    }
                    try? await Task.sleep(for: .seconds(3))
                    print("HANGREPRO stream: user prompt")
                    send(#"{"type":"message_start","message":{"role":"user","id":"u-live","content":"How many instances of `maestro` did I have in my pi sessions?"}}"#)
                    send(#"{"type":"message_end","message":{"role":"user","id":"u-live","content":"How many instances of `maestro` did I have in my pi sessions?"}}"#)
                    send(#"{"type":"agent_start"}"#)
                    send(#"{"type":"turn_start"}"#)
                    try? await Task.sleep(for: .milliseconds(400))
                    send(#"{"type":"message_start","message":{"role":"assistant","id":"a-live","content":[]}}"#)
                    send(#"{"type":"message_update","assistantMessageEvent":{"type":"thinking_start","contentIndex":0}}"#)
                    let thought = "The user wants to know how many pi sessions mention maestro. I should grep the sessions directory for the string and count the files, being careful to exclude the current session. "
                    for i in 0..<160 {
                        let delta = String(thought.dropFirst((i * 17) % thought.count).prefix(24))
                        send("{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"thinking_delta\",\"contentIndex\":0,\"delta\":\(Self.jsonString(delta))}}")
                        try? await Task.sleep(for: .milliseconds(30))
                    }
                    send(#"{"type":"message_update","assistantMessageEvent":{"type":"thinking_end","contentIndex":0}}"#)
                    send(#"{"type":"message_update","assistantMessageEvent":{"type":"text_start","contentIndex":1}}"#)
                    let answer = "Across your pi sessions there are **12 files** mentioning `maestro`.\n\n- 7 in `Doximity-Claude`\n- 3 in `iOS-Doximity`\n- 2 elsewhere\n\n| Project | Count |\n|---|---|\n| Doximity-Claude | 7 |\n| iOS-Doximity | 3 |\n\nWant the list?"
                    var offset = answer.startIndex
                    while offset < answer.endIndex {
                        let end = answer.index(offset, offsetBy: 9, limitedBy: answer.endIndex) ?? answer.endIndex
                        send("{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"contentIndex\":1,\"delta\":\(Self.jsonString(String(answer[offset..<end])))}}")
                        offset = end
                        try? await Task.sleep(for: .milliseconds(30))
                    }
                    send("{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"id\":\"a-live\",\"content\":[{\"type\":\"thinking\",\"thinking\":\(Self.jsonString(String(repeating: thought, count: 3)))},{\"type\":\"text\",\"text\":\(Self.jsonString(answer))}]}}")
                    send(#"{"type":"turn_end","context":{"tokens":36300,"contextWindow":175000,"percent":20.74}}"#)
                    send(#"{"type":"agent_end"}"#)
                    send(#"{"type":"agent_settled"}"#)
                    print("HANGREPRO stream: done")
                }
            }
        }
        let pane = try HerdrRenderFixtures.piCapablePane()
        let model = HerdrRenderFixtures.demoModel()
        let workspace = try #require(model.workspace(id: "demo1|w1"))
        let task = Task { @MainActor in
            await store.follow(model: model, pane: pane)
        }
        defer { task.cancel() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !store.hasContent, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.hasContent)

        let probe = HangProbe()
        probe.start()
        defer { probe.stop() }

        let start = clock.now
        let result = try await HerdrRenderHarness.render(
            "stream-\(fixture).png",
            size: CGSize(width: 980, height: 760),
            settlePasses: 700
        ) {
            PiChatView(
                model: model,
                store: store,
                paneID: pane.id,
                interactionResponseAvailable: true,
                composerPane: pane,
                workspace: workspace,
                draft: .constant(""),
                attachments: .constant([]),
                focusRequest: 0,
                interactionResponder: PiInteractionResponder()
            )
        }
        print("HANGREPRO streaming render elapsed=\(start.duration(to: clock.now)) phase=\(store.phase) turns=\(store.turns.count) maxStall=\(probe.maxStall)")
        result.expectSubstantial()
    }

    nonisolated static func streamEvent(_ cursor: Int, _ event: String) throws -> PiConversationStreamEvent {
        let envelope = try JSONDecoder().decode(
            PiConversationEnvelope.self,
            from: Data(
                """
                {"protocol":{"name":"herdr.pi.semantic","version":1},"pane_id":"w1:p1","session_id":"01a05f50-51ff-7e92-b6c1-4855bfe57850","cursor":"\(cursor)","event":\(event)}
                """.utf8
            )
        )
        return .envelope(envelope)
    }

    nonisolated static func jsonString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value])
        let text = String(decoding: data, as: UTF8.self)
        return String(text.dropFirst().dropLast())
    }

    @Test("Layout cost per row kind (40 rows each)")
    func rowKindCosts() async throws {
        let clock = ContinuousClock()
        func tool(_ i: Int, status: PiToolInvocation.Status = .succeeded) -> PiToolInvocation {
            PiToolInvocation(id: "tool:\(i)", callID: "c\(i)", name: "bash", arguments: .string("ls -la /tmp/project/\(i)"), result: .string("done \(i)"), status: status, startedAt: Date(), finishedAt: Date())
        }
        func thinking(_ i: Int) -> PiThinkingBlock {
            PiThinkingBlock(id: "t\(i)", text: "Thinking about step \(i) of the plan and what to do next.", isStreaming: false, isRedacted: false, startedAt: Date())
        }
        func assistant(_ i: Int) -> PiAssistantBlock {
            PiAssistantBlock(id: "a\(i)", text: "Step \(i): checked the **repository** state and found `\(i)` files that need a closer look before moving on.", status: .complete, timestamp: nil)
        }
        let groups = (0..<40).map { i in PiTurnSegmentation.segments(for: [.thinking(thinking(i)), .tool(tool(i))]).compactMap { seg -> PiWorkingGroup? in if case let .working(g) = seg { return g }; return nil }.first! }
        var results: [(String, Duration)] = []
        func measure(_ name: String, @ViewBuilder content: () -> some View) async throws {
            let start = clock.now
            _ = try await HerdrRenderHarness.render("rowcost-\(name).png", size: CGSize(width: 980, height: 3000), settlePasses: 1) { content() }
            results.append((name, start.duration(to: clock.now)))
        }
        try await measure("baseline-empty") { Color.clear }
        try await measure("plainText") { VStack(alignment: .leading, spacing: 10) { ForEach(0..<40, id: \.self) { i in Text("Step \(i): plain text row") } } }
        try await measure("assistantMarkdown") { VStack(alignment: .leading, spacing: 10) { ForEach(0..<40, id: \.self) { i in PiAssistantMessageView(block: assistant(i)) } } }
        try await measure("workingGroupCollapsed") { VStack(alignment: .leading, spacing: 10) { ForEach(0..<40, id: \.self) { i in PiWorkingGroupView(group: groups[i]) } } }
        try await measure("toolCardCollapsed") { VStack(alignment: .leading, spacing: 10) { ForEach(0..<40, id: \.self) { i in PiToolCardView(tool: tool(i)) } } }
        try await measure("thinkingCollapsed") { VStack(alignment: .leading, spacing: 10) { ForEach(0..<40, id: \.self) { i in PiThinkingDisclosureView(block: thinking(i)) } } }
        try await measure("wgHeaderOnly-HStack") { VStack(alignment: .leading, spacing: 10) { ForEach(0..<40, id: \.self) { i in
            HStack(spacing: 9) {
                Image(systemName: "gearshape.2").foregroundStyle(HerdrTheme.muted).frame(width: 18, height: 18)
                Text("Clanking").herdrFont(.caption, weight: .semibold).foregroundStyle(HerdrTheme.mist)
                Text("\(i) steps · Command").herdrFont(.caption).foregroundStyle(HerdrTheme.muted).lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").herdrFont(.caption2, weight: .semibold)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(HerdrTheme.graphite.opacity(0.55), in: RoundedRectangle(cornerRadius: 11))
            .frame(minHeight: 44)
        } } }
        try await measure("wgHeader-noSymbols") { VStack(alignment: .leading, spacing: 10) { ForEach(0..<40, id: \.self) { i in
            HStack(spacing: 9) {
                Circle().fill(HerdrTheme.muted).frame(width: 18, height: 18)
                Text("Clanking").herdrFont(.caption, weight: .semibold).foregroundStyle(HerdrTheme.mist)
                Text("\(i) steps · Command").herdrFont(.caption).foregroundStyle(HerdrTheme.muted).lineLimit(1)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(HerdrTheme.graphite.opacity(0.55), in: RoundedRectangle(cornerRadius: 11))
            .frame(minHeight: 44)
        } } }
        try await measure("wgHeader-systemFont") { VStack(alignment: .leading, spacing: 10) { ForEach(0..<40, id: \.self) { i in
            HStack(spacing: 9) {
                Circle().fill(HerdrTheme.muted).frame(width: 18, height: 18)
                Text("Clanking").font(.caption.weight(.semibold)).foregroundStyle(HerdrTheme.mist)
                Text("\(i) steps · Command").font(.caption).foregroundStyle(HerdrTheme.muted).lineLimit(1)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(HerdrTheme.graphite.opacity(0.55), in: RoundedRectangle(cornerRadius: 11))
            .frame(minHeight: 44)
        } } }
        try await measure("wgHeader-inButton") { VStack(alignment: .leading, spacing: 10) { ForEach(0..<40, id: \.self) { i in
            Button {} label: {
                HStack(spacing: 9) {
                    Circle().fill(HerdrTheme.muted).frame(width: 18, height: 18)
                    Text("Clanking").font(.caption.weight(.semibold)).foregroundStyle(HerdrTheme.mist)
                    Text("\(i) steps · Command").font(.caption).foregroundStyle(HerdrTheme.muted).lineLimit(1)
                    Spacer(minLength: 8)
                }
                .frame(minHeight: HerdrTheme.minHitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(HerdrTheme.graphite.opacity(0.55), in: RoundedRectangle(cornerRadius: 11))
            .frame(minHeight: 44)
        } } }
        for (name, duration) in results {
            print("HANGREPRO rowcost \(name) elapsed=\(duration)")
        }
    }

    nonisolated static func hasFixture(_ fixture: String) -> Bool {
        FileManager.default.fileExists(atPath: fixtureDirectory.appending(path: fixture).path)
    }

    static func loadStore(fixture: String) async throws -> (PiConversationStore, Task<Void, Never>) {
        let url = fixtureDirectory.appending(path: fixture)
        let data = try Data(contentsOf: url)
        let snapshot = try JSONDecoder().decode(PiConversationSnapshot.self, from: data)
        let store = PiConversationStore()
        store.snapshotProvider = { _ in snapshot }
        store.eventsProvider = { _, _ in AsyncThrowingStream { _ in } }
        let pane = try HerdrRenderFixtures.piCapablePane()
        let model = HerdrAppModel(arguments: [])
        let task = Task { @MainActor in
            await store.follow(model: model, pane: pane)
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !store.hasContent, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.hasContent, "fixture \(fixture) produced no turns")
        print("HANGREPRO fixture=\(fixture) loaded turns=\(store.turns.count) items=\(store.turns.reduce(0) { $0 + $1.items.count })")
        return (store, task)
    }
}


/// Off-main-thread probe: pings the main actor twice a second and logs
/// footprint + stall so the xcodebuild log shows progress even if the main
/// thread wedges.
final class HangProbe: Sendable {
    private struct State {
        var acked: UInt64 = 0
        var running = false
        var maxStall: Double = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var maxStall: Double { state.withLock { $0.maxStall } }

    func start() {
        state.withLock { $0.running = true }
        let thread = Thread { [self] in
            var sequence: UInt64 = 0
            var outstandingSince: Date?
            let started = Date()
            while true {
                Thread.sleep(forTimeInterval: 0.5)
                let (stillRunning, ack) = state.withLock { ($0.running, $0.acked) }
                if !stillRunning { return }
                let stalled: Double
                if let since = outstandingSince, ack < sequence {
                    stalled = Date().timeIntervalSince(since)
                } else {
                    stalled = 0
                    outstandingSince = nil
                }
                state.withLock { $0.maxStall = max($0.maxStall, stalled) }
                print("HANGPROBE t=\(String(format: "%.1f", Date().timeIntervalSince(started)))s footprintMB=\(HerdrPerfDiagnostics.currentFootprintMB()) mainStall=\(String(format: "%.1f", stalled))s")
                if outstandingSince == nil {
                    sequence += 1
                    outstandingSince = Date()
                    let seq = sequence
                    Task { @MainActor in
                        self.state.withLock { $0.acked = max($0.acked, seq) }
                    }
                }
            }
        }
        thread.name = "hang.probe"
        thread.start()
    }

    func stop() {
        state.withLock { $0.running = false }
    }
}
