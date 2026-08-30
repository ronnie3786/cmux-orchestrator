import Foundation
import Testing
@testable import herdr_harness_mac

struct ActiveWorkBoardDocumentTests {
    @Test("Embedded Active Work route keeps secrets out of the URL")
    func embeddedRoute() throws {
        let token = "secret-\"token\""
        let configuration = try #require(
            ServerConfiguration(urlString: "https://herdr.example.test/base", token: token)
        )
        let document = ActiveWorkBoardDocument(configuration: configuration)

        #expect(document.url.absoluteString == "https://herdr.example.test/base/board/?embed=1")
        #expect(!document.url.absoluteString.contains(token))
        #expect(document.bootstrapScript.contains("__HERDR_NATIVE_CONFIG__"))
        #expect(document.bootstrapScript.contains("Object.freeze"))
        #expect(document.bootstrapScript.contains("secret-\\\"token\\\""))
        let escapedBaseURL = configuration.baseURL.absoluteString.replacingOccurrences(of: "/", with: "\\/")
        #expect(document.bootstrapScript.contains(escapedBaseURL))
    }
}
