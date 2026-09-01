import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Rename tab client", .serialized)
struct HerdrAPIClientRenameTabTests {
    @Test("Renames a tab through the raw tab endpoint")
    func renameTabUsesPatchAndLabelBody() async throws {
        RenameTabURLProtocol.recorder.reset()
        let configuration = try #require(ServerConfiguration(urlString: "http://localhost:9092", token: "test"))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [RenameTabURLProtocol.self]
        let client = HerdrAPIClient(configuration: configuration, session: URLSession(configuration: sessionConfiguration))

        try await client.renameTab(id: "w1:t2", label: "Renamed tab")

        let request = try #require(RenameTabURLProtocol.recorder.request())
        #expect(request.method == "PATCH")
        #expect(request.path == "/api/v1/tabs/w1:t2")
        let body = try #require(request.body)
        #expect(try JSONSerialization.jsonObject(with: body) as? [String: String] == ["label": "Renamed tab"])
    }
}

private final class RenameTabURLProtocol: URLProtocol {
    static let recorder = RenameTabRequestRecorder()

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
        client?.urlProtocol(self, didLoad: Data("{\"ok\":true}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class RenameTabRequestRecorder: @unchecked Sendable {
    struct RecordedRequest {
        let method: String
        let path: String
        let body: Data?
    }

    private let lock = NSLock()
    private var recordedRequest: RecordedRequest?

    func reset() {
        lock.withLock { recordedRequest = nil }
    }

    func record(_ request: URLRequest) {
        lock.withLock {
            recordedRequest = RecordedRequest(
                method: request.httpMethod ?? "",
                path: request.url?.path ?? "",
                body: request.httpBody ?? data(from: request.httpBodyStream)
            )
        }
    }

    private func data(from stream: InputStream?) -> Data? {
        guard let stream else { return nil }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)

        while true {
            let bytesRead = stream.read(&buffer, maxLength: buffer.count)
            guard bytesRead >= 0 else { return nil }
            guard bytesRead > 0 else { return data }
            data.append(contentsOf: buffer.prefix(bytesRead))
        }
    }

    func request() -> RecordedRequest? {
        lock.withLock { recordedRequest }
    }
}
