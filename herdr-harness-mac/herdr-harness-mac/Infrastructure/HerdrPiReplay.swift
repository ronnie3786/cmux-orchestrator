#if DEBUG
import Foundation

/// Debug-only replay of a recorded Pi conversation into the demo-mode app.
///
/// Set `HERDR_PI_REPLAY_SNAPSHOT` to a `/pi/snapshot` JSON file and
/// `HERDR_PI_REPLAY_EVENTS` to a JSON-lines file of
/// `{"delay_ms": 30, "envelope": {...}}` records, then launch with
/// `-HerdrDemoMode`. Demo pane `w1:p1` becomes a Pi-capable chat whose
/// transcript is the snapshot; sending any prompt from the composer (or
/// `HERDR_PI_REPLAY_AUTOSTART_SECONDS` elapsing) streams the recorded
/// envelopes through the real store, reducer, and views. This exists to
/// reproduce main-thread freezes with production data on a developer Mac
/// without touching a live harness.
@MainActor
final class HerdrPiReplay {
    static let paneRawID = "w1:p1"
    static let machineID = "demo1"

    static let shared: HerdrPiReplay? = {
        let environment = ProcessInfo.processInfo.environment
        guard let snapshotPath = environment["HERDR_PI_REPLAY_SNAPSHOT"], !snapshotPath.isEmpty,
              let eventsPath = environment["HERDR_PI_REPLAY_EVENTS"], !eventsPath.isEmpty
        else { return nil }
        let autostart = environment["HERDR_PI_REPLAY_AUTOSTART_SECONDS"].flatMap(Double.init)
        return HerdrPiReplay(
            snapshotURL: URL(fileURLWithPath: snapshotPath),
            eventsURL: URL(fileURLWithPath: eventsPath),
            autostartSeconds: autostart
        )
    }()

    private struct Record: Decodable {
        let delayMs: Double?
        let envelope: PiConversationEnvelope

        enum CodingKeys: String, CodingKey {
            case delayMs = "delay_ms"
            case envelope
        }
    }

    private let snapshotURL: URL
    private let eventsURL: URL
    private let autostartSeconds: Double?
    private var armed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var didStream = false

    private init(snapshotURL: URL, eventsURL: URL, autostartSeconds: Double?) {
        self.snapshotURL = snapshotURL
        self.eventsURL = eventsURL
        self.autostartSeconds = autostartSeconds
        if let autostartSeconds {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(autostartSeconds))
                self?.arm()
            }
        }
    }

    func handles(_ pane: HerdrPane) -> Bool {
        pane.paneID == Self.paneRawID && pane.machineID == Self.machineID
    }

    func snapshot() throws -> PiConversationSnapshot {
        let data = try Data(contentsOf: snapshotURL)
        return try JSONDecoder().decode(PiConversationSnapshot.self, from: data)
    }

    /// Marks the recorded turn as ready to stream. Called when a prompt is
    /// sent from the composer, mirroring the moment the real app froze.
    func arm() {
        guard !armed else { return }
        armed = true
        NSLog("HerdrPiReplay: armed, streaming %@", eventsURL.lastPathComponent)
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func events() -> AsyncThrowingStream<PiConversationStreamEvent, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(512)) { continuation in
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                if self.didStream {
                    // The turn has already been delivered; keep the stream alive.
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(15))
                        continuation.yield(.activity)
                    }
                    return
                }
                if !self.armed {
                    await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                        self.waiters.append(waiter)
                    }
                }
                guard !Task.isCancelled else { return }
                self.didStream = true
                do {
                    let text = try String(contentsOf: self.eventsURL, encoding: .utf8)
                    let decoder = JSONDecoder()
                    var count = 0
                    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                        try Task.checkCancellation()
                        let record = try decoder.decode(Record.self, from: Data(line.utf8))
                        if let delay = record.delayMs, delay > 0 {
                            try await Task.sleep(for: .milliseconds(delay))
                        }
                        HerdrPerfDiagnostics.streamBacklog.noteYielded(.pi)
                        if case .dropped = continuation.yield(.envelope(record.envelope)) {
                            HerdrPerfDiagnostics.streamBacklog.noteOverflow(.pi)
                            continuation.finish(throwing: APIError.streamBacklogOverflow)
                            return
                        }
                        count += 1
                    }
                    NSLog("HerdrPiReplay: delivered %d envelopes", count)
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(15))
                        continuation.yield(.activity)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Demo pane `w1:p1` re-stamped as a connected Pi session so the pane
    /// auto-selects chat and the composer submits through the semantic path.
    static func piCapable(_ pane: HerdrPane) -> HerdrPane {
        let capability = try? JSONDecoder().decode(
            PiSemanticCapability.self,
            from: Data(
                """
                {"available":true,"connected":true,"protocolVersion":1,"sessionId":"replay",
                 "cursor":"1","capabilities":{"prompt":true,"steer":true,"followUp":true,"abort":true,
                 "listModels":false,"setModel":false,"setThinkingLevel":false,"interactionResponse":true}}
                """.utf8
            )
        )
        return HerdrPane(
            paneID: pane.paneID,
            terminalID: pane.terminalID,
            workspaceID: pane.workspaceID,
            tabID: pane.tabID,
            focused: pane.focused,
            agentStatus: pane.agentStatus,
            revision: pane.revision,
            cwd: pane.cwd,
            foregroundCWD: pane.foregroundCWD,
            label: pane.label,
            title: pane.title,
            agent: "pi",
            displayAgent: "Pi",
            terminalTitle: pane.terminalTitle,
            terminalTitleStripped: pane.terminalTitleStripped,
            stateLabels: pane.stateLabels,
            tokens: pane.tokens,
            piSemantic: capability,
            firstSeenAt: pane.firstSeenAt,
            lastActivityAt: pane.lastActivityAt,
            workingSince: pane.workingSince
        )
    }
}
#endif
