import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Agent result artifacts", .serialized)
@MainActor
struct AgentResultArtifactTests {
    @Test("Camel-case metadata decodes and stamps a machine-scoped identity")
    func decodingAndStamping() throws {
        let response = try JSONDecoder().decode(
            ResultArtifactsResponse.self,
            from: Data(
                """
                {
                  "ok": true,
                  "artifacts": [{
                    "id": "art_123",
                    "originType": "pane",
                    "originId": "w1:p2",
                    "sessionId": "session-7",
                    "kind": "file",
                    "title": "Quarterly review",
                    "filename": "review.pdf",
                    "contentType": "application/pdf",
                    "byteSize": 4096,
                    "createdAt": "2026-09-02T20:00:00Z",
                    "downloadPath": "/api/v1/result-artifacts/art_123/content"
                  }]
                }
                """.utf8
            )
        )

        let artifact = try #require(response.artifacts.first).stamped(machineID: "work-mac")
        #expect(response.ok)
        #expect(artifact.rawID == "art_123")
        #expect(artifact.id == "work-mac|art_123")
        #expect(artifact.machineID == "work-mac")
        #expect(artifact.originType == .pane)
        #expect(artifact.originID == "w1:p2")
        #expect(artifact.sessionID == "session-7")
        #expect(artifact.kind == .file)
        #expect(artifact.displayTitle == "Quarterly review")
        #expect(artifact.byteSize == 4096)
        #expect(artifact.createdDate != nil)
    }

    @Test("Individual malformed or unsafe artifact metadata is rejected")
    func rejectsUnsafeMetadata() {
        let javascriptLink = Data(
            """
            {"id":"a","originType":"agent_run","originId":"r1","kind":"link","title":"Nope","createdAt":"now","url":"javascript:alert(1)"}
            """.utf8
        )
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AgentResultArtifact.self, from: javascriptLink)
        }

        let missingDownload = Data(
            """
            {"id":"a","originType":"pane","originId":"p1","kind":"file","title":"Nope","filename":"x.txt","createdAt":"now"}
            """.utf8
        )
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AgentResultArtifact.self, from: missingDownload)
        }

        let unboundedDownload = Data(
            """
            {"id":"a","originType":"pane","originId":"p1","kind":"file","title":"Nope","filename":"x.txt","createdAt":"now","downloadPath":"/api/v1/result-artifacts/a/content"}
            """.utf8
        )
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AgentResultArtifact.self, from: unboundedDownload)
        }

        let oversizedDownload = Data(
            """
            {"id":"a","originType":"pane","originId":"p1","kind":"file","title":"Nope","filename":"x.txt","byteSize":536870913,"createdAt":"now","downloadPath":"/api/v1/result-artifacts/a/content"}
            """.utf8
        )
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AgentResultArtifact.self, from: oversizedDownload)
        }
    }

    @Test("Unsupported entries cannot poison an otherwise valid machine inventory")
    func responseSkipsUnsupportedEntries() throws {
        let response = try JSONDecoder().decode(
            ResultArtifactsResponse.self,
            from: Data(
                """
                {
                  "ok": true,
                  "artifacts": [
                    {"id":"unsafe","originType":"agent_run","originId":"r1","kind":"link","title":"Nope","createdAt":"now","url":"javascript:alert(1)"},
                    {"id":"safe-file","originType":"pane","originId":"p1","kind":"file","title":"Report","filename":"report.pdf","byteSize":12,"createdAt":"2026-09-02T20:00:00Z","downloadPath":"/api/v1/result-artifacts/safe-file/content"},
                    {"id":"too-large","originType":"pane","originId":"p2","kind":"file","title":"Large","filename":"large.mov","byteSize":536870913,"createdAt":"2026-09-02T20:00:01Z","downloadPath":"/api/v1/result-artifacts/too-large/content"},
                    {"id":"safe-link","originType":"agent_run","originId":"r2","kind":"link","title":"Preview","createdAt":"2026-09-02T20:00:02Z","url":"https://example.com/preview"}
                  ]
                }
                """.utf8
            )
        )

        #expect(response.artifacts.map(\.rawID) == ["safe-file", "safe-link"])

        let malformedEnvelopes = [
            #"{"artifacts":[]}"#,
            #"{"ok":null,"artifacts":[]}"#,
            #"{"ok":true}"#,
            #"{"ok":true,"artifacts":null}"#,
            #"{"ok":true,"artifacts":{}}"#,
        ]
        for malformedEnvelope in malformedEnvelopes {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(
                    ResultArtifactsResponse.self,
                    from: Data(malformedEnvelope.utf8)
                )
            }
        }
    }

    @Test("Named SSE events retain artifact metadata for immediate HUD insertion")
    func eventPayloadDecoding() throws {
        var parser = HerdrSSEParser()
        #expect(parser.consume(line: "event: result_artifact.created") == nil)
        let event = parser.consume(
            line: "data: {\"id\":\"art_live\",\"originType\":\"agent_run\",\"originId\":\"run-1\",\"sessionId\":null,\"kind\":\"link\",\"title\":\"Live result\",\"filename\":null,\"contentType\":null,\"byteSize\":null,\"createdAt\":\"2026-09-02T20:00:00Z\",\"url\":\"https://example.com/live\"}"
        )

        #expect(event?.event == "result_artifact.created")
        let artifact = try #require(AgentResultArtifact(eventData: event?.data))
        #expect(artifact.rawID == "art_live")
        #expect(artifact.originType == .agentRun)
        #expect(artifact.kind == .link)
    }

    @Test("Deduping is local to a machine and preserves identical server IDs across machines")
    func machineScopedDeduping() throws {
        let defaults = try testDefaults("AgentResultArtifactTests.deduping")
        defer { defaults.removePersistentDomain(forName: "AgentResultArtifactTests.deduping") }
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"], userDefaults: defaults)
        let original = fileArtifact(id: "art_same", title: "First")
        let duplicate = fileArtifact(id: "art_same", title: "Duplicate")

        model.ingestResultArtifacts(
            [original, duplicate],
            machineID: "devbox",
            replacingMachineSlice: true
        )
        model.ingestResultArtifacts(
            [original],
            machineID: "work-mac",
            replacingMachineSlice: true
        )

        #expect(model.resultArtifacts.count == 2)
        #expect(Set(model.resultArtifacts.map(\.id)) == ["devbox|art_same", "work-mac|art_same"])
        #expect(model.resultArtifacts.first(where: { $0.machineID == "devbox" })?.title == "First")

        model.ingestResultArtifactEvent(
            fileArtifact(id: "art_same", title: "Fresh event"),
            machineID: "devbox"
        )
        #expect(model.resultArtifacts.count == 2)
        #expect(model.resultArtifacts.first?.id == "devbox|art_same")
        #expect(model.resultArtifacts.first?.title == "Fresh event")
    }

    @Test("SSE results arriving during a list request survive its stale response")
    func staleListPreservesLaterEventUntilCurrentReconciliation() throws {
        let suiteName = "AgentResultArtifactTests.reconciliation.race"
        let defaults = try testDefaults(suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"], userDefaults: defaults)
        let existing = fileArtifact(id: "art_existing", title: "Existing")
        let late = fileArtifact(id: "art_late", title: "Arrived live")
        model.ingestResultArtifacts(
            [existing],
            machineID: "devbox",
            replacingMachineSlice: true
        )

        let staleRequest = model.beginResultArtifactListRequest(machineID: "devbox")
        model.ingestResultArtifactEvent(late, machineID: "devbox")
        #expect(model.reconcileResultArtifactList(
            [existing],
            machineID: "devbox",
            request: staleRequest
        ))

        #expect(model.resultArtifacts.map(\.id) == ["devbox|art_late", "devbox|art_existing"])

        // This request begins after the event, so its response is genuinely
        // current and may authoritatively prune a result absent from the list.
        let currentRequest = model.beginResultArtifactListRequest(machineID: "devbox")
        #expect(model.reconcileResultArtifactList(
            [existing],
            machineID: "devbox",
            request: currentRequest
        ))
        #expect(model.resultArtifacts.map(\.id) == ["devbox|art_existing"])
    }

    @Test("Older overlapping list responses cannot overwrite newer reconciliation")
    func supersededListResponseIsIgnored() throws {
        let suiteName = "AgentResultArtifactTests.reconciliation.overlap"
        let defaults = try testDefaults(suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"], userDefaults: defaults)
        let live = linkArtifact(id: "art_live")

        let olderRequest = model.beginResultArtifactListRequest(machineID: "work-mac")
        model.ingestResultArtifactEvent(live, machineID: "work-mac")
        let newerRequest = model.beginResultArtifactListRequest(machineID: "work-mac")
        #expect(model.reconcileResultArtifactList(
            [live],
            machineID: "work-mac",
            request: newerRequest
        ))
        #expect(!model.reconcileResultArtifactList(
            [],
            machineID: "work-mac",
            request: olderRequest
        ))

        #expect(model.resultArtifacts.map(\.id) == ["work-mac|art_live"])
    }

    @Test("Opened ledger persists exact machine-scoped presentation IDs")
    func ledgerPersistence() throws {
        let defaults = try testDefaults("AgentResultArtifactTests.ledger")
        defer { defaults.removePersistentDomain(forName: "AgentResultArtifactTests.ledger") }

        let first = AgentResultArtifactOpenedLedger(userDefaults: defaults)
        first.markOpened("devbox|art_same")

        let reloaded = AgentResultArtifactOpenedLedger(userDefaults: defaults)
        #expect(reloaded.contains("devbox|art_same"))
        #expect(!reloaded.contains("work-mac|art_same"))
    }

    @Test("Opened ledger keeps the newest bounded entries and expires old history")
    func ledgerRetention() throws {
        let suiteName = "AgentResultArtifactTests.ledger.retention"
        let defaults = try testDefaults(suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var current = Date(timeIntervalSince1970: 1_000)
        let policy = AgentResultArtifactOpenedLedger.RetentionPolicy(
            maximumEntryCount: 3,
            maximumAge: 10
        )
        let ledger = AgentResultArtifactOpenedLedger(
            userDefaults: defaults,
            retentionPolicy: policy,
            now: { current }
        )

        ledger.markOpened("machine|a")
        current.addTimeInterval(1)
        ledger.markOpened("machine|b")
        current.addTimeInterval(1)
        ledger.markOpened("machine|c")
        current.addTimeInterval(1)
        ledger.markOpened("machine|a") // Refresh recency for an existing ID.
        current.addTimeInterval(1)
        ledger.markOpened("machine|d")

        #expect(ledger.contains("machine|a"))
        #expect(!ledger.contains("machine|b"))
        #expect(ledger.contains("machine|c"))
        #expect(ledger.contains("machine|d"))

        let reloaded = AgentResultArtifactOpenedLedger(
            userDefaults: defaults,
            retentionPolicy: policy,
            now: { current }
        )
        #expect(reloaded.contains("machine|a"))
        current.addTimeInterval(11)
        #expect(!reloaded.contains("machine|a"))
        #expect(!reloaded.contains("machine|c"))
        #expect(!reloaded.contains("machine|d"))
    }

    @Test("Canonical machine inventories collect handled tombstones only after server removal")
    func ledgerCanonicalReconciliation() throws {
        let suiteName = "AgentResultArtifactTests.ledger.reconciliation"
        let defaults = try testDefaults(suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var current = Date(timeIntervalSince1970: 10_000)
        let ledger = AgentResultArtifactOpenedLedger(userDefaults: defaults, now: { current })
        ledger.markOpened("devbox|art_live")
        ledger.markOpened("devbox|art_gone")
        ledger.markOpened("work-mac|art_remote")

        current.addTimeInterval(3_650 * 24 * 60 * 60)
        #expect(ledger.contains("devbox|art_live"))

        ledger.reconcile(
            machineID: "devbox",
            activePresentationIDs: ["devbox|art_live"]
        )

        #expect(ledger.contains("devbox|art_live"))
        #expect(!ledger.contains("devbox|art_gone"))
        #expect(ledger.contains("work-mac|art_remote"))
    }

    @Test("Cache destinations contain traversal and separate matching IDs by machine")
    func safeCachePaths() throws {
        let root = temporaryDirectory("safe-cache")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AgentResultArtifactCache(rootURL: root)
        let malicious = AgentResultArtifact(
            id: "art_same",
            originType: .pane,
            originID: "p1",
            kind: .file,
            title: "Report",
            filename: "../../../../evil?.pdf",
            contentType: "application/pdf",
            byteSize: 1,
            createdAt: "2026-09-02T20:00:00Z",
            downloadPath: "/api/v1/result-artifacts/art_same/content"
        )
        let devboxURL = try cache.destinationURL(for: malicious.stamped(machineID: "devbox"))
        let workMacURL = try cache.destinationURL(for: malicious.stamped(machineID: "work-mac"))

        #expect(devboxURL.path.hasPrefix(root.standardizedFileURL.path + "/"))
        #expect(devboxURL.lastPathComponent == "evil-.pdf")
        #expect(!devboxURL.path.contains("/../"))
        #expect(devboxURL != workMacURL)

        let inferredHTML = AgentResultArtifact(
            id: "art_html",
            originType: .agentRun,
            originID: "run-1",
            kind: .file,
            title: "Interactive dashboard",
            contentType: "text/html",
            createdAt: "2026-09-02T20:00:00Z",
            downloadPath: "/api/v1/result-artifacts/art_html/content"
        ).stamped(machineID: "devbox")
        #expect(try cache.destinationURL(for: inferredHTML).pathExtension == "html")
    }

    @Test("Cache preparation rejects symlinked app-owned directories")
    func cacheRejectsSymlinkDirectories() throws {
        let anchor = temporaryDirectory("cache-symlink-anchor")
        let actualRoot = anchor.appending(path: "actual", directoryHint: .isDirectory)
        let linkedRoot = anchor.appending(path: "linked", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: anchor) }
        try FileManager.default.createDirectory(at: actualRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: actualRoot)
        let artifact = fileArtifact(id: "art_symlink", title: "Unsafe")
            .stamped(machineID: "devbox")

        #expect(throws: AgentResultArtifactCache.CacheError.self) {
            try AgentResultArtifactCache(rootURL: linkedRoot).prepareDestinationURL(for: artifact)
        }

        let safeRoot = anchor.appending(path: "safe", directoryHint: .isDirectory)
        let safeCache = AgentResultArtifactCache(rootURL: safeRoot)
        let destination = try safeCache.destinationURL(for: artifact)
        try FileManager.default.createDirectory(at: safeRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: destination.deletingLastPathComponent(),
            withDestinationURL: actualRoot
        )
        #expect(throws: AgentResultArtifactCache.CacheError.self) {
            try safeCache.prepareDestinationURL(for: artifact)
        }
    }

    @Test("Cache cleanup expires old files then evicts least-recent files to its byte cap")
    func cacheRetention() throws {
        let root = temporaryDirectory("cache-retention")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 2_000)
        let cache = AgentResultArtifactCache(
            rootURL: root,
            retentionPolicy: .init(
                maximumFileCount: 3,
                maximumByteCount: 9,
                maximumAge: 10
            )
        )
        let stale = try writeCacheFile(
            root: root,
            directory: "result-stale",
            filename: "stale.txt",
            byteCount: 1,
            modifiedAt: now.addingTimeInterval(-11)
        )
        let oldestLive = try writeCacheFile(
            root: root,
            directory: "result-oldest",
            filename: "oldest.txt",
            byteCount: 4,
            modifiedAt: now.addingTimeInterval(-3)
        )
        let middle = try writeCacheFile(
            root: root,
            directory: "result-middle",
            filename: "middle.txt",
            byteCount: 4,
            modifiedAt: now.addingTimeInterval(-2)
        )
        let newest = try writeCacheFile(
            root: root,
            directory: "result-newest",
            filename: "newest.txt",
            byteCount: 5,
            modifiedAt: now.addingTimeInterval(-1)
        )

        let report = try cache.cleanup(now: now)

        #expect(report.removedPaths == [stale.path, oldestLive.path])
        #expect(report.remainingFileCount == 2)
        #expect(report.remainingByteCount == 9)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(!FileManager.default.fileExists(atPath: oldestLive.path))
        #expect(FileManager.default.fileExists(atPath: middle.path))
        #expect(FileManager.default.fileExists(atPath: newest.path))
    }

    @Test("Opening cleanup never removes the cache file currently being opened")
    func openingProtectsCurrentCacheFile() async throws {
        let suiteName = "AgentResultArtifactTests.open.protected-cache"
        let defaults = try testDefaults(suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = temporaryDirectory("protected-cache")
        defer { try? FileManager.default.removeItem(at: root) }
        let current = Date(timeIntervalSince1970: 3_000)
        let cache = AgentResultArtifactCache(
            rootURL: root,
            retentionPolicy: .init(
                maximumFileCount: 0,
                maximumByteCount: 0,
                maximumAge: 0
            )
        )
        let ledger = AgentResultArtifactOpenedLedger(userDefaults: defaults, now: { current })
        var acceptedURL: URL?
        let opener = AgentResultArtifactOpener(
            cache: cache,
            ledger: ledger,
            openURL: {
                acceptedURL = $0
                return FileManager.default.fileExists(atPath: $0.path)
            },
            now: { current }
        )
        let artifact = fileArtifact(id: "art_protected", title: "Protected")
            .stamped(machineID: "devbox")
        let destination = try cache.destinationURL(for: artifact)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("hello".utf8).write(to: destination)
        try FileManager.default.setAttributes(
            [.modificationDate: current.addingTimeInterval(-60)],
            ofItemAtPath: destination.path
        )
        let disposable = try writeCacheFile(
            root: root,
            directory: "result-disposable",
            filename: "disposable.txt",
            byteCount: 1,
            modifiedAt: current.addingTimeInterval(-60)
        )

        let openedURL = try await opener.open(artifact)

        #expect(openedURL == destination)
        #expect(acceptedURL == destination)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: disposable.path))
        #expect(ledger.contains(artifact.id))
    }

    @Test("Successful file open marks the ledger only after Launch Services accepts")
    func successfulFileOpen() async throws {
        let defaults = try testDefaults("AgentResultArtifactTests.open.success")
        defer { defaults.removePersistentDomain(forName: "AgentResultArtifactTests.open.success") }
        let root = temporaryDirectory("open-success")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = AgentResultArtifactOpenedLedger(userDefaults: defaults)
        var acceptedURL: URL?
        let opener = AgentResultArtifactOpener(
            cache: AgentResultArtifactCache(rootURL: root),
            ledger: ledger,
            openURL: {
                acceptedURL = $0
                return FileManager.default.fileExists(atPath: $0.path)
            }
        )
        let bytes = Data("hello".utf8)
        let artifact = fileArtifact(id: "art_open", title: "Hello", byteSize: Int64(bytes.count))
            .stamped(machineID: "devbox")

        let openedURL = try await opener.open(
            artifact,
            downloadFile: { destination in
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try bytes.write(to: destination, options: .atomic)
            }
        )

        #expect(openedURL == acceptedURL)
        #expect(ledger.contains("devbox|art_open"))
    }

    @Test("Rejected open remains unviewed and retryable")
    func failedOpenDoesNotAdvanceLedger() async throws {
        let defaults = try testDefaults("AgentResultArtifactTests.open.failure")
        defer { defaults.removePersistentDomain(forName: "AgentResultArtifactTests.open.failure") }
        let ledger = AgentResultArtifactOpenedLedger(userDefaults: defaults)
        let opener = AgentResultArtifactOpener(
            cache: AgentResultArtifactCache(rootURL: temporaryDirectory("open-failure")),
            ledger: ledger,
            openURL: { _ in false }
        )
        let artifact = linkArtifact(id: "art_link").stamped(machineID: "work-mac")

        do {
            try await opener.open(artifact)
            Issue.record("Expected Launch Services rejection")
        } catch let error as AgentResultArtifactOpener.OpenError {
            guard case .applicationUnavailable = error else {
                Issue.record("Unexpected open error: \(error)")
                return
            }
        }

        #expect(!ledger.contains("work-mac|art_link"))
    }

    @Test("Rapid link double-clicks share one in-flight open")
    func linkOpenIsSingleFlight() async throws {
        let suiteName = "AgentResultArtifactTests.open.single-flight"
        let defaults = try testDefaults(suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"], userDefaults: defaults)
        let probe = SuspendedArtifactOpenProbe()
        model.resultArtifactOpenOverride = { _, _ in
            await probe.perform()
        }
        let artifact = linkArtifact(id: "art_double_click").stamped(machineID: "work-mac")

        let firstOpen = Task { await model.openResultArtifact(artifact) }
        await probe.waitUntilStarted()
        #expect(model.resultArtifactPhase(id: artifact.id) == .opening)

        let secondOpen = Task { await model.openResultArtifact(artifact) }
        await Task.yield()
        await Task.yield()
        #expect(await probe.count() == 1)

        await probe.release()
        await firstOpen.value
        await secondOpen.value
        #expect(model.resultArtifactPhase(id: artifact.id) == .opened)
    }

    @Test("Dismissed results retire immediately and stay handled after model reload")
    func dismissWithoutOpeningPersists() throws {
        let suiteName = "AgentResultArtifactTests.dismiss"
        let defaults = try testDefaults(suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let artifact = linkArtifact(id: "art_unwanted")

        let first = HerdrAppModel(
            arguments: ["HerdrTests", "-HerdrDemoMode"],
            userDefaults: defaults
        )
        first.ingestResultArtifacts(
            [artifact],
            machineID: "work-mac",
            replacingMachineSlice: true
        )
        let stamped = try #require(first.resultArtifacts.first)
        #expect(first.unopenedResultArtifacts.map(\.id) == [stamped.id])
        first.dismissResultArtifact(stamped)
        #expect(first.unopenedResultArtifacts.isEmpty)

        let reloaded = HerdrAppModel(
            arguments: ["HerdrTests", "-HerdrDemoMode"],
            userDefaults: defaults
        )
        reloaded.ingestResultArtifacts(
            [artifact],
            machineID: "work-mac",
            replacingMachineSlice: true
        )
        #expect(reloaded.unopenedResultArtifacts.isEmpty)
    }

    @Test("Reading a pane clears only that machine's session outputs and retains inline history")
    func paneReadRetainsResults() throws {
        let suiteName = "AgentResultArtifactTests.pane-read"
        let defaults = try testDefaults(suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = HerdrAppModel(arguments: ["HerdrTests", "-HerdrDemoMode"], userDefaults: defaults)
        let pane = try JSONDecoder().decode(HerdrPane.self, from: Data(
            #"{"pane_id":"p1","workspace_id":"w1","tab_id":"t1","agent_status":"idle"}"#.utf8
        )).stamped(machineID: "work-mac")
        let artifact = AgentResultArtifact(
            id: "result", originType: .pane, originID: "p1", kind: .link,
            title: "Report", createdAt: "2026-09-06T12:00:00Z", url: URL(string: "https://example.com/report")
        )
        model.ingestResultArtifacts([artifact], machineID: "work-mac", replacingMachineSlice: true)
        model.ingestResultArtifacts([artifact], machineID: "devbox", replacingMachineSlice: true)

        model.acknowledgeUnreadAlerts(for: pane)

        #expect(model.resultArtifacts.count == 2)
        #expect(model.unopenedResultArtifacts.map(\.machineID) == ["devbox"])
        #expect(model.resultArtifactPhase(id: "work-mac|result") == .opened)
        model.ingestResultArtifacts([artifact], machineID: "work-mac", replacingMachineSlice: true)
        #expect(model.unopenedResultArtifacts.map(\.machineID) == ["devbox"])
    }

    @Test("Client lists and atomically downloads authenticated artifact content")
    func authenticatedClientDownload() async throws {
        ResultArtifactURLProtocol.recorder.reset()
        let configuration = try #require(
            ServerConfiguration(urlString: "http://localhost:9092", token: "secret-token")
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ResultArtifactURLProtocol.self]
        let client = HerdrAPIClient(
            configuration: configuration,
            session: URLSession(configuration: sessionConfiguration)
        )
        let root = temporaryDirectory("client-download")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "nested/movie.mp4")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let response = try await client.fetchResultArtifacts()
        try await client.downloadResultArtifactContent(
            id: "art_download",
            expectedByteSize: 11,
            to: destination
        )

        #expect(response.artifacts.map(\.rawID) == ["art_download"])
        #expect(try Data(contentsOf: destination) == Data("video-bytes".utf8))
        #expect(ResultArtifactURLProtocol.recorder.requests() == [
            .init(path: "/api/v1/result-artifacts", authorization: "Bearer secret-token"),
            .init(path: "/api/v1/result-artifacts/art_download/content", authorization: "Bearer secret-token"),
        ])
    }

    private func fileArtifact(
        id: String,
        title: String,
        byteSize: Int64 = 5
    ) -> AgentResultArtifact {
        AgentResultArtifact(
            id: id,
            originType: .pane,
            originID: "w1:p1",
            sessionID: "session-1",
            kind: .file,
            title: title,
            filename: "result.txt",
            contentType: "text/plain",
            byteSize: byteSize,
            createdAt: "2026-09-02T20:00:00Z",
            downloadPath: "/api/v1/result-artifacts/\(id)/content"
        )
    }

    private func linkArtifact(id: String) -> AgentResultArtifact {
        AgentResultArtifact(
            id: id,
            originType: .agentRun,
            originID: "run-1",
            kind: .link,
            title: "Research",
            createdAt: "2026-09-02T20:00:00Z",
            url: URL(string: "https://example.com/research")
        )
    }

    private func testDefaults(_ suiteName: String) throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func temporaryDirectory(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "herdr-artifact-tests-\(suffix)-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func writeCacheFile(
        root: URL,
        directory: String,
        filename: String,
        byteCount: Int,
        modifiedAt: Date
    ) throws -> URL {
        let directoryURL = root.appending(path: directory, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let url = directoryURL.appending(path: filename, directoryHint: .notDirectory)
        try Data(repeating: 0x41, count: byteCount).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt],
            ofItemAtPath: url.path
        )
        return url.standardizedFileURL
    }
}

private actor SuspendedArtifactOpenProbe {
    private var invocationCount = 0
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func perform() async {
        invocationCount += 1
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilStarted() async {
        guard invocationCount == 0 else { return }
        await withCheckedContinuation { continuation in
            startWaiter = continuation
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func count() -> Int { invocationCount }
}

private final class ResultArtifactURLProtocol: URLProtocol {
    static let recorder = ResultArtifactRequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.recorder.record(request)
        let data: Data
        if url.path == "/api/v1/result-artifacts" {
            data = Data(
                """
                {"ok":true,"artifacts":[{"id":"art_download","originType":"agent_run","originId":"run-1","sessionId":null,"kind":"file","title":"Movie","filename":"movie.mp4","contentType":"video/mp4","byteSize":11,"createdAt":"2026-09-02T20:00:00Z","downloadPath":"/api/v1/result-artifacts/art_download/content"}]}
                """.utf8
            )
        } else {
            data = Data("video-bytes".utf8)
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "application/octet-stream",
                "Content-Length": String(data.count),
            ]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ResultArtifactRequestRecorder: @unchecked Sendable {
    struct Request: Equatable {
        let path: String
        let authorization: String?
    }

    private let lock = NSLock()
    private var recordedRequests: [Request] = []

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        recordedRequests = []
    }

    func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        recordedRequests.append(
            Request(
                path: request.url?.path ?? "",
                authorization: request.value(forHTTPHeaderField: "Authorization")
            )
        )
    }

    func requests() -> [Request] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }
}
