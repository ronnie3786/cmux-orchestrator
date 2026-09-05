import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Quick voice delivery", .serialized)
@MainActor
struct QuickVoiceSessionTests {
    @Test("Unconfirmed notes survive restart and retry with the original identity and machine")
    func pendingRecovery() async throws {
        let suite = "QuickVoiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let request = QuickVoiceRequest(requestId: "stable-note", text: "Investigate the build", cwd: "/tmp")
        let pending = QuickVoiceSession.Pending(machineID: "work", request: request)
        defaults.set(try JSONEncoder().encode(pending), forKey: "herdr.quickVoice.pending")
        QuickVoiceURLProtocol.requests.withLock { $0 = [] }
        let machine = HerdrMachine(id: "work", name: "Work Mac", urlString: "http://localhost:9092")
        let config = try #require(ServerConfiguration(urlString: machine.urlString, token: "test"))
        let urlConfig = URLSessionConfiguration.ephemeral
        urlConfig.protocolClasses = [QuickVoiceURLProtocol.self]
        let client = HerdrAPIClient(configuration: config, session: URLSession(configuration: urlConfig))
        let model = HerdrAppModel(arguments: [], userDefaults: defaults)
        model.machines = [machine]
        model.clientFactory = { _ in client }
        model.prepareRuntime(for: machine, generation: model.connectionGeneration)
        model.machineStates[machine.id] = .live
        let state = QuickVoiceSession(defaults: defaults)
        #expect(state.hasPendingSubmission)
        #expect(state.transcript == request.text)
        state.configure(model: model)
        state.retry()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while state.phase != .idle, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(state.phase == .idle)
        #expect(!state.hasPendingSubmission)
        #expect(defaults.data(forKey: "herdr.quickVoice.pending") == nil)
        let posts = QuickVoiceURLProtocol.requests.withLock { $0 }
        #expect(posts.count == 1)
        let body = try #require(posts.first)
        let decoded = try JSONDecoder().decode(QuickVoiceRequest.self, from: body)
        #expect(decoded.requestId == "stable-note")
        #expect(decoded.cwd == "/tmp")
        #expect(decoded.text == request.text)
    }

    @Test("Terminal states distinguish blocked and failed quests from completed work")
    func reportStates() throws {
        for (status, label) in [("done", "Finished"), ("needs_attention", "Needs your attention"), ("failed", "Couldn’t complete request")] {
            let data = Data(QuickVoiceURLProtocol.job(status: status).utf8)
            let job = try JSONDecoder().decode(QuickVoiceJob.self, from: data)
            #expect(job.isFinished)
            #expect(job.statusLabel == label)
        }
        let running = try JSONDecoder().decode(QuickVoiceJob.self, from: Data(QuickVoiceURLProtocol.job(status: "running").utf8))
        #expect(!running.isFinished)
    }
}

import Synchronization

private final class QuickVoiceURLProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[Data]>([])
    static func job(status: String = "planning") -> String {
        #"{"id":"stable-note","text":"Investigate the build","cwd":"/tmp","title":"Build investigation","status":""# + status + #"","createdAt":1,"tasks":[],"messages":[],"error":null}"#
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.httpMethod == "POST" {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            Self.requests.withLock { $0.append(data) }
        }
        let payload = request.httpMethod == "POST" ? "{\"ok\":true,\"job\":\(Self.job())}" : "{\"ok\":true,\"jobs\":[]}"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
