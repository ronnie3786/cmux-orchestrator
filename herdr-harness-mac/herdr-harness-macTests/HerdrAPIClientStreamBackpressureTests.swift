import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Herdr API stream backpressure")
struct HerdrAPIClientStreamBackpressureTests {
    @Test("A slow terminal consumer resyncs after buffer overflow")
    func slowConsumerOverflows() async throws {
        let client = HerdrAPIClient(configuration: configuration, session: makeSession())
        let stream = await client.terminalEvents(paneID: "pane")

        var delivered = 0
        do {
            for try await _ in stream {
                delivered += 1
                try await Task.sleep(for: .milliseconds(5))
            }
            Issue.record("Expected stream backlog overflow")
        } catch let error as APIError {
            guard case .streamBacklogOverflow = error else {
                Issue.record("Expected stream backlog overflow, got \(error)")
                return
            }
        }
        #expect(delivered < 600)
    }

    @Test("A fast terminal consumer receives the complete stream")
    func fastConsumerReceivesAllFrames() async throws {
        let client = HerdrAPIClient(configuration: configuration, session: makeSession())
        let stream = await client.terminalEvents(paneID: "pane")

        var delivered = 0
        do {
            for try await _ in stream {
                delivered += 1
            }
            Issue.record("Expected the server to close the stream")
        } catch let error as APIError {
            guard case .streamEnded = error else {
                Issue.record("Expected normal stream end, got \(error)")
                return
            }
        }
        #expect(delivered == 600)
    }

    private var configuration: ServerConfiguration {
        ServerConfiguration(urlString: "http://localhost:9092", token: "test")!
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TerminalStreamURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class TerminalStreamURLProtocol: URLProtocol {
    private static let streamData: Data = {
        (1...600).map { sequence in
            let frame = "{\"bytes\":\"WA==\",\"encoding\":\"base64\",\"full\":true,\"height\":1,\"seq\":\(sequence),\"type\":\"terminal.frame\",\"width\":1}"
            return "event: terminal.frame\ndata: \(frame)\n"
        }
        .joined()
        .data(using: .utf8)!
    }()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.streamData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
