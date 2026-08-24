import AppKit
import Foundation
import SwiftUI
import Testing
@testable import herdr_harness_mac

/// Headless visual verification.
///
/// There is no screen-recording or UI-automation permission in this
/// environment, so the only way to *see* the Mac port is to render its views
/// offscreen. The unit-test bundle is hosted by the real app, so the views get
/// the app's fonts, bundle, and appearance without asking for anything extra —
/// see `HerdrRenderHarness` for why this uses `NSHostingView` rather than
/// `ImageRenderer`.
///
/// What this suite is for: catching "the window is one flat rectangle of ink"
/// regressions and giving a human something to look at during the port. It is
/// deliberately NOT a pixel-diff harness — layout of system chrome offscreen is
/// not reliable enough for that, and hashing screenshots would make the suite
/// flap on every SF Symbol tweak. The assertions are structural: the image
/// rendered, it is the requested size, and the PNG on disk is substantial
/// enough to contain real content.
///
/// PNGs land in `$HERDR_RENDER_DIR` when that is set and writable, and in a
/// subdirectory of the temp directory otherwise — see `HerdrRenderHarness.directory`
/// for why the sandbox usually decides that for you. Either way the suite never
/// writes into the repo.
@Suite("Demo screenshot renders", .serialized)
@MainActor
struct DemoScreenshotRenderTests {

    // MARK: - 01 · Root shell

    @Test("Root shell renders the navigator beside the detail column")
    func rendersRootShell() async throws {
        let model = HerdrRenderFixtures.demoModel()
        model.openPane(id: "demo1|w1:p2")
        let shell = HerdrShellState()
        let pane = try #require(model.pane(id: model.selectedPaneID))
        #expect(shell.resolvedScope(for: model) == .session)

        let result = try await HerdrRenderHarness.render(
            "01-root.png",
            size: CGSize(width: 1240, height: 820)
        ) {
            // `AppRootView`'s `NavigationSplitView` does not survive an
            // offscreen snapshot: the sidebar column comes back as a blank
            // white slab because the split view's backdrop is drawn outside
            // the hierarchy `cacheDisplay` walks (the detail column is fine).
            // So the shell is composed the way `WorkspaceNavigationView`
            // composes it — `HerdrSidebarView` at its ideal 320pt width, the
            // hairline, and the resolved detail scope — minus system chrome.
            HStack(spacing: 0) {
                HerdrSidebarView(model: model, openPane: { _ in }, openWorkspace: { _ in })
                    .frame(width: 320)

                Rectangle()
                    .fill(HerdrTheme.surface)
                    .frame(width: 1)

                PaneSessionView(model: model, pane: pane)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(HerdrTheme.ink)
        }

        result.expectSubstantial()
    }

    // MARK: - 02 · Sidebar

    @Test("Sidebar renders the workspace tree")
    func rendersSidebar() async throws {
        let model = HerdrRenderFixtures.demoModel()
        model.selectedPaneID = "demo1|w1:p2"
        model.starredChatIDs = ["demo1|w1:p1", "demo1|w2:p1"]

        let result = try await HerdrRenderHarness.render(
            "02-sidebar.png",
            size: CGSize(width: 300, height: 760)
        ) {
            HerdrSidebarView(model: model, openPane: { _ in }, openWorkspace: { _ in })
        }

        result.expectSubstantial()
    }

    @Test("Sidebar changes at XX-Large text scale")
    func rendersSidebarAtXXLargeTextScale() async throws {
        let model = HerdrRenderFixtures.demoModel()
        model.selectedPaneID = "demo1|w1:p2"
        model.starredChatIDs = ["demo1|w1:p1", "demo1|w2:p1"]

        let defaultResult = try await HerdrRenderHarness.render(
            "02-sidebar.png",
            size: CGSize(width: 300, height: 760)
        ) {
            HerdrSidebarView(model: model, openPane: { _ in }, openWorkspace: { _ in })
        }

        let xxLargeResult = try await HerdrRenderHarness.render(
            "02b-sidebar-xxlarge.png",
            size: CGSize(width: 300, height: 760)
        ) {
            HerdrSidebarView(model: model, openPane: { _ in }, openWorkspace: { _ in })
                .environment(\.herdrFontScale, .xxLarge)
        }

        defaultResult.expectSubstantial()
        xxLargeResult.expectSubstantial()
        #expect(xxLargeResult.byteCount != defaultResult.byteCount)
    }

    // MARK: - 03 · Attention deck

    @Test("Attention deck renders alerts and the live queue")
    func rendersAttentionDeck() async throws {
        let model = HerdrRenderFixtures.demoModel()

        let result = try await HerdrRenderHarness.render(
            "03-attention.png",
            size: CGSize(width: 900, height: 760)
        ) {
            AttentionView(model: model) { _, _ in }
        }

        result.expectSubstantial()
    }

    // MARK: - 04 · Workspace overview

    @Test("Workspace overview renders the fleet summary, hero, and pane cards")
    func rendersWorkspaceOverview() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let workspace = try #require(model.workspace(id: "demo1|w1"))
        model.selectedPaneID = "demo1|w1:p1"

        let result = try await HerdrRenderHarness.render(
            "04-workspace.png",
            size: CGSize(width: 900, height: 760)
        ) {
            WorkspacePaneListView(model: model, workspace: workspace) { _ in }
        }

        result.expectSubstantial()
    }

    // MARK: - 05 · Pane session, terminal mode

    @Test("Pane session renders a streamed terminal frame above the composer")
    func rendersTerminalSession() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let pane = try #require(model.pane(id: "demo1|w1:p2"))
        let workspace = try #require(model.workspace(containing: pane))
        let grid = HerdrRenderFixtures.cannedTerminalGrid(
            text: DemoData.terminalText(for: pane.id)
        )

        // Pins the canned frame itself: an ANSI payload the grid rejects would
        // otherwise render as an empty, and still plausibly sized, terminal.
        #expect(grid.plainText.contains("Waiting for your response"))

        let result = try await HerdrRenderHarness.render(
            "05-terminal.png",
            size: CGSize(width: 900, height: 760)
        ) {
            // Mirrors the body of `PaneSessionView.terminalContent` with a
            // canned full frame pushed through `TerminalGrid`. Mounting
            // `PaneSessionView` itself would work, but demo mode has no SSE
            // feed, so it only ever reaches `.snapshot` — the attributed-grid
            // path that `.stream` uses would go unrendered. Every view below is
            // the production one.
            ZStack {
                HerdrBackground()

                VStack(spacing: 0) {
                    PaneSessionHeader(model: model, pane: pane, store: PiConversationStore())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)

                    Rectangle()
                        .fill(HerdrTheme.surface)
                        .frame(height: 1)

                    VStack(spacing: 0) {
                        PaneTerminalView(
                            pane: pane,
                            output: grid.plainText,
                            attributedOutput: grid.attributedText(),
                            revision: 4_812,
                            dimensions: "\(grid.columns)×\(grid.rows)",
                            source: .stream,
                            isFollowing: .constant(true),
                            isRefreshing: false,
                            isKeyboardFocused: true,
                            refresh: {}
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        PromptComposerView(
                            model: model,
                            pane: pane,
                            workspace: workspace,
                            draft: .constant("yes, update and verify"),
                            attachments: .constant([]),
                            focusRequest: 0
                        )
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 10)
                    }
                }
            }
        }

        result.expectSubstantial()
    }

    // MARK: - 06 · Pi chat timeline

    @Test("Pi chat renders a synthetic transcript with thinking, code, and tools")
    func rendersPiChatTimeline() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let workspace = try #require(model.workspace(id: "demo1|w1"))
        let pane = try HerdrRenderFixtures.piCapablePane()
        let store = try await HerdrRenderFixtures.populatedPiStore()

        #expect(store.hasContent)
        #expect(store.canSendCommands)
        #expect(store.phase == .working)

        let result = try await HerdrRenderHarness.render(
            "06-pi-chat.png",
            size: CGSize(width: 900, height: 760)
        ) {
            // `PiChatView` takes every piece of state by injection, so the whole
            // chat surface — connection banner, context meter, timeline, and the
            // Pi-configured composer — renders from the fixture store.
            PiChatView(
                model: model,
                store: store,
                pane: pane,
                workspace: workspace,
                draft: .constant(""),
                attachments: .constant([]),
                focusRequest: 0
            )
        }

        result.expectSubstantial()
    }

    // MARK: - 07 · Composer with its tool row

    @Test("Composer renders the tool row above the input")
    func rendersComposerWithAuxiliaryBar() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let pane = try HerdrRenderFixtures.piCapablePane()
        let workspace = try #require(model.workspace(id: "demo1|w1"))

        let result = try await HerdrRenderHarness.render(
            "07-composer.png",
            size: CGSize(width: 900, height: 300)
        ) {
            // Composer owns one always-visible row, tools left and terminal keys right.
            // Pin its widest form: ViewThatFits lays out candidates to measure them, and a
            // losing candidate's tools can linger in an offscreen NSHostingView snapshot.
            // Without that pin, this test may document a second row the app never draws.
            // At 900pt, .automatic would choose this widest form anyway, so this PNG is
            // still the real on-screen layout. Runtime .automatic behavior stays untouched.
            PromptComposerView(
                model: model,
                pane: pane,
                workspace: workspace,
                draft: .constant("steer: keep the follow loop off scenePhase"),
                attachments: .constant([]),
                focusRequest: 0,
                piConfiguration: HerdrRenderFixtures.composerConfiguration(),
                toolRowFit: .pinnedWidest
            )
            .padding(12)
        }

        result.expectSubstantial()
    }

    // MARK: - 08 · Herd Pulse menu bar card

    @Test("Herd Pulse menu bar card renders aggregate-only counts")
    func rendersHerdPulseCard() async throws {
        let model = HerdrRenderFixtures.demoModel()
        let pulse = await HerdrRenderFixtures.runningPulse(for: model)

        #expect(pulse.contentState != nil)

        let result = try await HerdrRenderHarness.render(
            "08-pulse.png",
            size: CGSize(width: 360, height: 420)
        ) {
            HerdPulseMenuBarCard(pulse: pulse)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        result.expectSubstantial()
    }
}

// MARK: - Harness

/// Renders SwiftUI views to PNG files without screen recording or UI
/// automation.
///
/// `ImageRenderer` was the obvious tool and it does not work here: it never
/// lays out `ScrollView` content (every scrolling screen came out as a bare ink
/// rectangle) and it draws AppKit-backed controls — `TextField` above all — as
/// yellow "unsupported" placeholders. So the harness mounts the view in a real
/// `NSHostingView` inside an offscreen `NSWindow`, lets AppKit lay it out, and
/// snapshots the view's backing store. The unit-test bundle is hosted by the
/// app, so this needs no entitlement the app does not already have.
enum HerdrRenderHarness {
    enum RenderError: Error, CustomStringConvertible {
        case bitmapUnavailable(String)
        case encodingFailed(String)

        var description: String {
            switch self {
            case let .bitmapUnavailable(name): "Could not allocate a bitmap for \(name)"
            case let .encodingFailed(name): "Could not encode \(name) as PNG"
            }
        }
    }

    struct RenderResult {
        let name: String
        let url: URL
        let byteCount: Int
        let pixelSize: CGSize
        let pointSize: CGSize

        /// A screen of Herdr chrome never encodes this small. A near-empty PNG
        /// is the signature of a view that failed to lay out offscreen, which
        /// is exactly the failure this suite exists to catch.
        func expectSubstantial(
            minimumBytes: Int = 8_192,
            sourceLocation: SourceLocation = #_sourceLocation
        ) {
            #expect(
                FileManager.default.fileExists(atPath: url.path),
                "\(name) was not written to \(url.path)",
                sourceLocation: sourceLocation
            )
            #expect(
                byteCount >= minimumBytes,
                "\(name) is only \(byteCount) bytes — the view probably did not lay out",
                sourceLocation: sourceLocation
            )
            #expect(
                pixelSize == CGSize(width: pointSize.width * scale, height: pointSize.height * scale),
                "\(name) rendered at \(pixelSize) instead of \(pointSize) at \(scale)x",
                sourceLocation: sourceLocation
            )
        }
    }

    /// Retina, so text is legible when a human opens the PNG.
    static let scale: CGFloat = 2

    /// Where the PNGs land: `$HERDR_RENDER_DIR`, else
    /// `$TEST_RUNNER_HERDR_RENDER_DIR`, else the temp directory.
    ///
    /// Two things constrain this, both measured rather than assumed:
    ///
    /// 1. Neither variable survives `xcodebuild … test` from a shell. A plain
    ///    environment variable is not forwarded into the test host, and the
    ///    `TEST_RUNNER_` prefix is a UI-test-runner mechanism that does nothing
    ///    for a hosted unit-test bundle. They *do* arrive from an Xcode scheme's
    ///    Test action, which is when this override is worth setting.
    /// 2. The host app is sandboxed (`herdr_harness_mac.entitlements`), so a
    ///    directory outside the app container is refused outright — writing to
    ///    `/private/tmp/...` fails with `NSCocoaErrorDomain 513 / EPERM`.
    ///
    /// Hence the writability probe and the fallback: a bad override degrades to
    /// the container temp directory instead of failing all eight renders. From
    /// a shell, collect the PNGs from where they actually land:
    ///
    ///     ~/Library/Containers/dev.ronnierocha.herdr-harness.herdr-harness-mac/Data/tmp/herdr-renders
    static let directory: URL = {
        let environment = ProcessInfo.processInfo.environment
        let configured = (environment["HERDR_RENDER_DIR"] ?? environment["TEST_RUNNER_HERDR_RENDER_DIR"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = FileManager.default.temporaryDirectory
            .appending(path: "herdr-renders", directoryHint: .isDirectory)
        if let configured, !configured.isEmpty {
            let requested = URL(fileURLWithPath: configured, isDirectory: true)
            if isWritable(requested) { return requested }
        }
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }()

    /// Renders `content` in an offscreen window and writes it as a PNG.
    ///
    /// `settlePasses` exists because SwiftUI lays lazy stacks out over several
    /// run-loop turns; snapshotting the first frame catches half-built scroll
    /// content. Each pass yields to the main run loop and re-layouts.
    @MainActor
    static func render(
        _ name: String,
        size: CGSize,
        settlePasses: Int = 8,
        @ViewBuilder content: () -> some View
    ) async throws -> RenderResult {
        let hosting = NSHostingView(
            rootView: content()
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark)
                .preferredColorScheme(.dark)
                .tint(HerdrTheme.accent)
                .background(HerdrTheme.ink)
        )
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: .darkAqua)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.contentView = hosting
        // Fully transparent, but in the window server: AppKit only materializes
        // some backgrounds (split-view sidebars, `NSVisualEffectView`) for a
        // window that has actually been ordered in. `cacheDisplay` draws the
        // view directly, so `alphaValue` never reaches the bitmap.
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        for _ in 0..<settlePasses {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(25))
        }
        hosting.layoutSubtreeIfNeeded()

        // A rep whose pixel dimensions are `scale`× its point size makes
        // `cacheDisplay` draw the view at Retina density regardless of which
        // screen (if any) the offscreen window is associated with.
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { throw RenderError.bitmapUnavailable(name) }
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.encodingFailed(name)
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try data.write(to: url, options: .atomic)

        return RenderResult(
            name: name,
            url: url,
            byteCount: data.count,
            pixelSize: CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh),
            pointSize: size
        )
    }

    private static func isWritable(_ directory: URL) -> Bool {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let probe = directory.appending(path: ".herdr-render-probe")
            try Data([0]).write(to: probe, options: .atomic)
            try? manager.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Fixtures

@MainActor
enum HerdrRenderFixtures {
    static func demoModel() -> HerdrAppModel {
        HerdrAppModel(arguments: ["HerdrRenderTests", "-HerdrDemoMode", "-HerdrResetSidebarState"])
    }

    /// Herd Pulse only publishes a content state while its defaults flag is on,
    /// so the fixture uses a private suite instead of touching the user's.
    static func runningPulse(for model: HerdrAppModel) async -> HerdPulseCoordinator {
        let defaults = UserDefaults(suiteName: "herdr.render.pulse") ?? .standard
        defaults.set(true, forKey: "herdr.herdPulse.enabled")
        let pulse = HerdPulseCoordinator(defaults: defaults)
        await pulse.synchronize(
            context: HerdPulseSyncContext(
                aggregate: HerdPulseAggregate(
                    workspaces: model.workspaces,
                    connectionState: model.connectionState
                ),
                serverConnection: nil
            )
        )
        return pulse
    }

    /// A pane whose `pi_semantic` block advertises the full v1 contract, decoded
    /// through the production decoder so the fixture cannot drift from the wire
    /// format. `HerdrPane` has no memberwise initializer for this field.
    static func piCapablePane() throws -> HerdrPane {
        try JSONDecoder().decode(
            HerdrPane.self,
            from: Data(
                """
                {
                  "pane_id": "w1:p1",
                  "workspace_id": "w1",
                  "tab_id": "w1:t1",
                  "agent_status": "working",
                  "revision": 184,
                  "cwd": "/Users/ronnie/Work/iOS-Doximity",
                  "title": "Refine member profile",
                  "agent": "pi",
                  "display_agent": "Pi",
                  "pi_semantic": {
                    "available": true,
                    "connected": true,
                    "protocolVersion": 1,
                    "sessionId": "session-render",
                    "cursor": 12,
                    "capabilities": {
                      "prompt": true,
                      "steer": true,
                      "followUp": true,
                      "abort": true,
                      "listModels": true,
                      "setModel": true,
                      "setThinkingLevel": true,
                      "interactionResponse": true
                    }
                  }
                }
                """.utf8
            )
        )
    }

    /// Demo mode has no live Pi session, so the transcript is built by driving
    /// the real reducer through `PiConversationStore.consume` with a synthetic
    /// event stream. Shapes are lifted from `PiConversationReducerTests` and
    /// `PiConversationDecodingTests` so the fixture stays honest about the wire
    /// contract: a user turn, a completed assistant turn with markdown and a
    /// fenced code block, a thinking block, a finished tool call, and a second
    /// assistant message still streaming.
    static func populatedPiStore() async throws -> PiConversationStore {
        let store = PiConversationStore()
        let envelopes = try piTranscriptEnvelopes()
        let stream = AsyncThrowingStream<PiConversationStreamEvent, any Error> { continuation in
            for envelope in envelopes {
                continuation.yield(.envelope(envelope))
            }
            continuation.finish()
        }
        _ = try await store.consume(stream)
        return store
    }

    static func composerConfiguration() -> PiPromptComposerConfiguration {
        PiPromptComposerConfiguration(
            capabilities: piCapabilities,
            phase: .working,
            isConnected: true,
            isSubmitting: false,
            isAborting: false,
            currentModel: PiModelIdentity(
                provider: "anthropic",
                id: "claude-opus-5",
                name: "Opus 5"
            ),
            availableModels: [
                PiAvailableModel(
                    provider: "anthropic",
                    modelID: "claude-opus-5",
                    name: "Opus 5",
                    reasoning: true,
                    contextWindow: 1_000_000
                ),
            ],
            isLoadingModels: false,
            isSettingModel: false,
            modelCatalogError: nil,
            isModelSwitchingUnsupported: false,
            submit: { _, _ in true },
            abort: { true },
            selectModel: { _ in true },
            retryLoadModels: {},
            thinkingLevel: "high",
            isSettingThinkingLevel: false,
            selectThinkingLevel: { _ in true }
        )
    }

    /// A canned full frame pushed through the production ANSI grid, so the
    /// terminal render exercises the same attributed-text path the live stream
    /// does rather than a plain `Text`.
    static func cannedTerminalGrid(text: String) -> TerminalGrid {
        let lines = text.components(separatedBy: "\n")
        let columns = max(64, (lines.map(\.count).max() ?? 64) + 2)
        let rows = max(1, lines.count)
        var grid = TerminalGrid(columns: columns, rows: rows)
        // Absolute cursor moves rather than newlines: the row a line lands on
        // is then independent of how the parser treats CR/LF pairs.
        let payload = lines.enumerated().reduce("\u{001B}[2J") { payload, entry in
            payload + "\u{001B}[\(entry.offset + 1);1H" + entry.element
        }
        _ = grid.apply(
            TerminalFrame(
                bytes: Data(payload.utf8).base64EncodedString(),
                encoding: "base64",
                full: true,
                height: rows,
                sequence: 4_812,
                type: "terminal.frame",
                width: columns
            )
        )
        return grid
    }

    private static let piCapabilities = PiSemanticCapabilities(
        prompt: true,
        steer: true,
        followUp: true,
        abort: true,
        listModels: true,
        setModel: true,
        setThinkingLevel: true,
        interactionResponse: true
    )

    private static func piTranscriptEnvelopes() throws -> [PiConversationEnvelope] {
        let assistantText = """
        Ported it. The Mac keeps the **dual feed** — SSE frames arbitrated against \
        the 850 ms snapshot poll — but the follow loop no longer tears down when the \
        window loses key status:

        - `scenePhase` gating is gone
        - `TerminalRefreshPolicy` is unchanged
        - the grid is now a focusable keyboard surface

        ```swift
        .task(id: followTaskID) {
            await followOutput()
        }
        ```

        Next I'll check the composer's Return-key mapping.

        ## Follow loop audit

        The dual feed held up under **12k events**. Inline `scenePhase` checks stay hot, and `TerminalRefreshPolicy.balanced` now drives the poll cadence.

        ### Next steps

        1. Wire `followTaskID` into the pane registry
        2. Drop the legacy `onChange` observer

        > The refresh policy must never outlive its pane — tear it down in `deinit`.

        ---

        Shipping this behind the `mac-follow-loop` flag.
        """

        let events: [String] = [
            #"{"type":"bridge.connection","connected":true}"#,
            #"{"type":"pi.model_select","model":{"provider":"anthropic","id":"claude-opus-5","name":"Opus 5"},"source":"set"}"#,
            #"{"type":"pi.thinking_level_select","level":"high"}"#,
            #"{"type":"turn_start"}"#,
            """
            {"type":"message_start","message":{"role":"user","id":"u1","timestamp":1786536000000,
            "content":"Port PaneSessionView to macOS and keep the terminal follow loop intact."}}
            """,
            """
            {"type":"message_end","message":{"role":"assistant","id":"a1","timestamp":1786536002000,
            "stopReason":"toolUse","content":[
              {"type":"thinking","thinking":"The iOS build tears the stream down on scenePhase changes. A Mac window behind another app is still being watched, so that gate has to go — but TerminalRefreshPolicy must stay byte-identical or the snapshot poll will fight the stream."},
              {"type":"text","text":\(jsonString(assistantText))},
              {"type":"toolCall","id":"call-1","name":"read","arguments":{"path":"Views/Pane/PaneSessionView.swift","limit":120}}
            ]}}
            """,
            """
            {"type":"tool_execution_end","toolCallId":"call-1","toolName":"read",
            "args":{"path":"Views/Pane/PaneSessionView.swift","limit":120},
            "result":{"content":"408 lines · struct PaneSessionView: View"},"isError":false}
            """,
            #"{"type":"turn_end","turnIndex":1,"context":{"tokens":48210,"contextWindow":192000,"percent":25.1},"cost":{"totalUSD":1.87,"totalTokens":51631}}"#,
            """
            {"type":"message_start","message":{"role":"assistant","id":"a2","timestamp":1786536005000,"content":[]}}
            """,
            #"{"type":"message_update","assistantMessageEvent":{"type":"text_start","contentIndex":0}}"#,
            """
            {"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,
            "delta":"Return sends, Shift/Option+Return breaks the line, and Command+Return always sends"}}
            """,
        ]

        return try events.enumerated().map { index, json in
            PiConversationEnvelope(
                paneID: "w1:p1",
                sessionID: "session-render",
                cursor: String(index + 1),
                event: try JSONDecoder().decode(PiJSONValue.self, from: Data(json.utf8))
            )
        }
    }

    /// Embeds a multi-line Swift string as a JSON string literal so the markdown
    /// fixture stays readable in source.
    private static func jsonString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value], options: [])
        guard let data, let array = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }
}
