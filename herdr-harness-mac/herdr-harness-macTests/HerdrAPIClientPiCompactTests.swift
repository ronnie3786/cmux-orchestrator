import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Pi compact client", .serialized)
struct HerdrAPIClientPiCompactTests {
    @Test("Compacts through the semantic Pi endpoint")
    func compactsConversation() async throws {
        PiCompactURLProtocol.recorder.reset()
        let configuration = try #require(
            ServerConfiguration(urlString: "http://localhost:9092", token: "test")
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [PiCompactURLProtocol.self]
        let client = HerdrAPIClient(
            configuration: configuration,
            session: URLSession(configuration: sessionConfiguration)
        )

        try await client.compactPiConversation(paneID: "w1:p2")

        #expect(PiCompactURLProtocol.recorder.requests() == [
            .init(method: "POST", path: "/api/v1/panes/w1:p2/pi/compact"),
        ])
    }
}

private final class PiCompactURLProtocol: URLProtocol {
    static let recorder = PiCompactRequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recorder.record(request)
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"ok\":true}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class PiCompactRequestRecorder: @unchecked Sendable {
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
