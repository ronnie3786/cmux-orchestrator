import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Pane alert client", .serialized)
struct HerdrAPIClientPaneAlertsTests {
    @Test("Marks pane alerts read through the pane endpoint")
    func marksPaneAlertsRead() async throws {
        PaneAlertsReadURLProtocol.recorder.reset()
        let configuration = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "test"))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [PaneAlertsReadURLProtocol.self]
        let client = HerdrAPIClient(configuration: configuration, session: URLSession(configuration: sessionConfiguration))

        try await client.markPaneAlertsRead(paneID: "w1:p2")

        #expect(PaneAlertsReadURLProtocol.recorder.requests() == [
            .init(method: "POST", path: "/api/v1/panes/w1:p2/alerts/read"),
        ])
    }
}

private final class PaneAlertsReadURLProtocol: URLProtocol {
    static let recorder = PaneAlertsReadRequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recorder.record(request)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"ok\":true,\"paneId\":\"w1:p2\",\"alerts\":[],\"unreadCount\":0}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class PaneAlertsReadRequestRecorder: @unchecked Sendable {
    struct RecordedRequest: Equatable {
        let method: String
        let path: String
    }

    private let lock = NSLock()
    private var recordedRequests: [RecordedRequest] = []

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        recordedRequests = []
    }

    func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        recordedRequests.append(
            RecordedRequest(method: request.httpMethod ?? "", path: request.url?.path ?? "")
        )
    }

    func requests() -> [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }
}
