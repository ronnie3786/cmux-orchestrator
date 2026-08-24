import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Cleanup async apply client", .serialized)
struct CleanupApplyClientTests {
    @Test("Apply retries a busy POST and every post-acceptance GET failure")
    func transientPollFailureRecovers() async throws {
        CleanupApplyURLProtocol.script.configure(.pollFailuresThenApplied)
        let client = try makeClient()
        let progress = CleanupApplyProgressRecorder()

        let result = try await client.applyCleanupRun(
            id: "clr_async",
            paneIDs: ["w3:p1"],
            workspaceIDs: [],
            onProgress: { envelope in await progress.record(envelope) }
        )

        #expect(result.complete == true)
        #expect(result.error == nil)
        #expect(result.applied.panes == ["w3:p1"])
        let requests = CleanupApplyURLProtocol.script.requests()
        #expect(requests.count == 9)
        #expect(requests.filter { $0.method == "POST" }.count == 2)
        #expect(requests.filter { $0.method == "GET" }.count == 7)
        #expect(await progress.statuses() == [.done, .partial, .applying, .applied])
        #expect(await progress.latest()?.applyResult?.applied.panes == ["w3:p1"])
    }

    @Test("Failed apply GET returns partial outcomes instead of throwing")
    func failedApplyReturnsPartialResult() async throws {
        CleanupApplyURLProtocol.script.configure(.failedWithPartialResult)
        let client = try makeClient()

        let result = try await client.applyCleanupRun(
            id: "clr_async",
            paneIDs: ["w3:p1", "w3:p2"],
            workspaceIDs: []
        )

        #expect(result.complete == false)
        #expect(result.error == "Fresh workspace snapshot failed")
        #expect(result.applied.panes == ["w3:p1"])
        #expect(result.skipped.first?.id == "w3:p2")
        #expect(CleanupApplyURLProtocol.script.requests().allSatisfy { $0.method == "GET" })
    }

    @Test("A lost accepted response probes GET and returns a failed partial result")
    func lostAcceptedResponseFindsFailedResult() async throws {
        CleanupApplyURLProtocol.script.configure(.lostAcceptedThenFailed)
        let client = try makeClient()

        let result = try await client.applyCleanupRun(
            id: "clr_async",
            paneIDs: ["w3:p1", "w3:p2"],
            workspaceIDs: []
        )

        #expect(result.complete == false)
        #expect(result.applied.panes == ["w3:p1"])
        #expect(result.error == "Pane w3:p2 could not be closed")
        let requests = CleanupApplyURLProtocol.script.requests()
        #expect(requests.map(\.method) == ["GET", "POST", "GET"])
    }

    @Test("A lost accepted response and transient start errors retry idempotently")
    func lostAcceptedResponseRecovers() async throws {
        CleanupApplyURLProtocol.script.configure(.transientStartFailuresThenApplied)
        let client = try makeClient()

        let result = try await client.applyCleanupRun(
            id: "clr_async",
            paneIDs: ["w3:p1"],
            workspaceIDs: []
        )

        #expect(result.complete == true)
        let requests = CleanupApplyURLProtocol.script.requests()
        #expect(requests.filter { $0.method == "POST" }.count == 6)
        #expect(requests.filter { $0.method == "GET" }.count == 7)
    }

    @Test("A bounded status outage becomes an explicit unknown result")
    func statusOutageIsBounded() async throws {
        CleanupApplyURLProtocol.script.configure(.statusOutage)
        let client = try makeClient(failureLimit: 3)

        do {
            _ = try await client.applyCleanupRun(id: "clr_async", paneIDs: [], workspaceIDs: [])
            Issue.record("Expected an explicit unknown cleanup status")
        } catch let APIError.cleanupApplyStatusUnknown(message) {
            #expect(message.contains("may still be ending sessions or closing panes"))
            #expect(message.contains("checking cleanup status"))
        } catch {
            Issue.record("Expected cleanupApplyStatusUnknown, got \(error)")
        }

        let requests = CleanupApplyURLProtocol.script.requests()
        #expect(requests.filter { $0.method == "POST" }.count == 1)
        #expect(requests.filter { $0.method == "GET" }.count == 4)
    }

    @Test("A terminal status without applyResult is bounded as status unknown")
    func terminalResultMissingIsBounded() async throws {
        CleanupApplyURLProtocol.script.configure(.terminalResultMissing)
        let client = try makeClient(failureLimit: 3)

        do {
            _ = try await client.applyCleanupRun(id: "clr_async", paneIDs: [], workspaceIDs: [])
            Issue.record("Expected a missing terminal result to become status unknown")
        } catch let APIError.cleanupApplyStatusUnknown(message) {
            #expect(message.contains("reading the final cleanup result"))
        } catch {
            Issue.record("Expected cleanupApplyStatusUnknown, got \(error)")
        }

        let requests = CleanupApplyURLProtocol.script.requests()
        #expect(requests.filter { $0.method == "POST" }.count == 1)
        #expect(requests.filter { $0.method == "GET" }.count == 4)
    }

    @Test("Busy apply acknowledgement retries become status unknown at the cap")
    func busyRetriesAreBounded() async throws {
        CleanupApplyURLProtocol.script.configure(.alwaysBusy)
        let client = try makeClient(failureLimit: 3)

        do {
            _ = try await client.applyCleanupRun(id: "clr_async", paneIDs: [], workspaceIDs: [])
            Issue.record("Expected the bounded cleanup-busy retry to become status unknown")
        } catch let APIError.cleanupApplyStatusUnknown(message) {
            #expect(message.contains("starting cleanup"))
        } catch {
            Issue.record("Expected cleanupApplyStatusUnknown, got \(error)")
        }
        #expect(CleanupApplyURLProtocol.script.requests().count == 6)
    }

    private func makeClient(failureLimit: Int = 8) throws -> HerdrAPIClient {
        let configuration = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "test"))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [CleanupApplyURLProtocol.self]
        return HerdrAPIClient(
            configuration: configuration,
            session: URLSession(configuration: sessionConfiguration),
            cleanupApplyPollInterval: .milliseconds(1),
            cleanupApplyConsecutiveFailureLimit: failureLimit
        )
    }
}

private actor CleanupApplyProgressRecorder {
    private var envelopes: [CleanupRunEnvelope] = []

    func record(_ envelope: CleanupRunEnvelope) {
        envelopes.append(envelope)
    }

    func statuses() -> [CleanupRunStatus] {
        envelopes.map(\.run.status)
    }

    func latest() -> CleanupRunEnvelope? {
        envelopes.last
    }
}

private final class CleanupApplyURLProtocol: URLProtocol {
    static let script = CleanupApplyURLProtocolScript()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch Self.script.next(for: request) {
        case .networkFailure:
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case let .response(status, body):
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private final class CleanupApplyURLProtocolScript: @unchecked Sendable {
    enum Scenario {
        case pollFailuresThenApplied
        case failedWithPartialResult
        case lostAcceptedThenFailed
        case transientStartFailuresThenApplied
        case statusOutage
        case terminalResultMissing
        case alwaysBusy
    }

    enum Stub {
        case networkFailure
        case response(status: Int, body: String)
    }

    struct RecordedRequest: Equatable {
        let method: String
        let path: String
    }

    private let lock = NSLock()
    private var scenario = Scenario.pollFailuresThenApplied
    private var postCount = 0
    private var getCount = 0
    private var recordedRequests: [RecordedRequest] = []

    func configure(_ scenario: Scenario) {
        lock.withLock {
            self.scenario = scenario
            postCount = 0
            getCount = 0
            recordedRequests = []
        }
    }

    func requests() -> [RecordedRequest] {
        lock.withLock { recordedRequests }
    }

    func next(for request: URLRequest) -> Stub {
        lock.withLock {
            let method = request.httpMethod ?? "GET"
            recordedRequests.append(.init(method: method, path: request.url?.path ?? ""))
            if method == "POST" {
                postCount += 1
                if case .alwaysBusy = scenario {
                    return .response(
                        status: 409,
                        body: #"{"ok":false,"error":{"code":"cleanup_busy","message":"A cleanup run is already active"}}"#
                    )
                }
                if case .transientStartFailuresThenApplied = scenario {
                    switch postCount {
                    case 1:
                        return .networkFailure
                    case 2:
                        return .response(status: 408, body: #"{"ok":false,"error":{"code":"timeout","message":"Timed out"}}"#)
                    case 3:
                        return .response(status: 429, body: #"{"ok":false,"error":{"code":"rate_limited","message":"Slow down"}}"#)
                    case 4:
                        return .response(status: 503, body: #"{"ok":false,"error":{"code":"unavailable","message":"Unavailable"}}"#)
                    case 5:
                        return .response(status: 409, body: #"{"ok":false,"error":{"code":"cleanup_busy","message":"Cleanup already accepted"}}"#)
                    default:
                        break
                    }
                }
                if case .lostAcceptedThenFailed = scenario {
                    return .networkFailure
                }
                if case .pollFailuresThenApplied = scenario, postCount == 1 {
                    return .response(
                        status: 409,
                        body: #"{"ok":false,"error":{"code":"cleanup_busy","message":"A cleanup run is already active"}}"#
                    )
                }
                return .response(
                    status: 202,
                    body: #"{"ok":true,"runId":"clr_async","status":"applying"}"#
                )
            }

            getCount += 1
            switch scenario {
            case .pollFailuresThenApplied:
                if getCount == 1 {
                    return .response(
                        status: 401,
                        body: #"{"ok":false,"error":{"code":"unauthorized","message":"Token expired"}}"#
                    )
                }
                if getCount == 2 {
                    return .response(status: 200, body: "{")
                }
                if getCount == 3 {
                    return .networkFailure
                }
                if getCount == 4 {
                    return .response(
                        status: 200,
                        body: #"{"ok":true,"run":{"runId":"clr_async","status":"done","phase":"done"}}"#
                    )
                }
                if getCount == 5 {
                    return .response(
                        status: 200,
                        body: #"{"ok":true,"run":{"runId":"clr_async","status":"partial","phase":"done"}}"#
                    )
                }
                if getCount == 6 {
                    return .response(
                        status: 200,
                        body: #"{"ok":true,"run":{"runId":"clr_async","status":"applying","phase":"applying"},"applyResult":{"ok":true,"complete":false,"applied":{"panes":[],"workspaces":[]},"skipped":[]}}"#
                    )
                }
                return .response(
                    status: 200,
                    body: #"{"ok":true,"run":{"runId":"clr_async","status":"applied","phase":"done"},"applyResult":{"ok":true,"complete":true,"applied":{"panes":["w3:p1"],"workspaces":[]},"skipped":[]}}"#
                )
            case .failedWithPartialResult:
                return .response(
                    status: 200,
                    body: #"{"ok":true,"run":{"runId":"clr_async","status":"failed","phase":"failed","error":"Fresh workspace snapshot failed"},"applyResult":{"ok":false,"complete":false,"applied":{"panes":["w3:p1"],"workspaces":[]},"skipped":[{"id":"w3:p2","reason":"R8:state_changed"}],"error":"Fresh workspace snapshot failed"}}"#
                )
            case .lostAcceptedThenFailed:
                if getCount == 1 {
                    return .response(
                        status: 200,
                        body: #"{"ok":true,"run":{"runId":"clr_async","status":"done","phase":"done"}}"#
                    )
                }
                return .response(
                    status: 200,
                    body: #"{"ok":true,"run":{"runId":"clr_async","status":"failed","phase":"failed"},"applyResult":{"ok":false,"complete":false,"applied":{"panes":["w3:p1"],"workspaces":[]},"skipped":[{"id":"w3:p2","reason":"close_failed"}],"error":"Pane w3:p2 could not be closed"}}"#
                )
            case .transientStartFailuresThenApplied:
                if getCount == 1 {
                    return .response(
                        status: 200,
                        body: #"{"ok":true,"run":{"runId":"clr_async","status":"done","phase":"done"}}"#
                    )
                }
                if getCount <= 6 {
                    return .response(
                        status: 200,
                        body: #"{"ok":true,"run":{"runId":"clr_async","status":"applying","phase":"applying"}}"#
                    )
                }
                return .response(
                    status: 200,
                    body: #"{"ok":true,"run":{"runId":"clr_async","status":"applied","phase":"done"},"applyResult":{"ok":true,"complete":true,"applied":{"panes":["w3:p1"],"workspaces":[]},"skipped":[]}}"#
                )
            case .statusOutage:
                if getCount == 1 {
                    return .response(
                        status: 200,
                        body: #"{"ok":true,"run":{"runId":"clr_async","status":"done","phase":"done"}}"#
                    )
                }
                return .networkFailure
            case .terminalResultMissing:
                if getCount == 1 {
                    return .response(
                        status: 200,
                        body: #"{"ok":true,"run":{"runId":"clr_async","status":"done","phase":"done"}}"#
                    )
                }
                return .response(
                    status: 200,
                    body: #"{"ok":true,"run":{"runId":"clr_async","status":"failed","phase":"failed"}}"#
                )
            case .alwaysBusy:
                return .response(
                    status: 200,
                    body: #"{"ok":true,"run":{"runId":"clr_async","status":"done","phase":"done"}}"#
                )
            }
        }
    }
}
