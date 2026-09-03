import Foundation
import Testing
@testable import herdr_harness_mac

struct PaneGitWebDocumentTests {
    @Test("Embedded Git route keeps identifiers in the fragment and secrets out of the URL")
    func embeddedRoute() throws {
        let token = "secret-\"token\""
        let configuration = try #require(
            ServerConfiguration(urlString: "https://herdr.example.test/base", token: token)
        )
        let document = PaneGitWebDocument(
            configuration: configuration,
            workspaceID: "workspace with spaces",
            paneID: "pane/1"
        )

        #expect(document.url.path == "/base/herdr-web")
        #expect(document.url.absoluteString.hasPrefix("https://herdr.example.test/base/herdr-web/#"))
        #expect(!document.url.absoluteString.contains(token))

        let assetURL = try #require(
            URL(string: "./assets/app.js", relativeTo: document.url)?.absoluteURL
        )
        #expect(assetURL.path == "/base/herdr-web/assets/app.js")

        let pageComponents = try #require(
            URLComponents(url: document.url, resolvingAgainstBaseURL: false)
        )
        var routeComponents = URLComponents()
        routeComponents.percentEncodedQuery = pageComponents.percentEncodedFragment
        let route = Dictionary(
            uniqueKeysWithValues: (routeComponents.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        #expect(route["ws"] == "workspace with spaces")
        #expect(route["pane"] == "pane/1")
        #expect(route["view"] == "git")
        #expect(route["embed"] == "1")
        #expect(document.bootstrapScript.contains("__HERDR_NATIVE_CONFIG__"))
        #expect(document.bootstrapScript.contains("secret-\\\"token\\\""))
        #expect(document.bootstrapScript.contains("\"hostIsLocal\""))
    }

    @Test("Navigation is limited to the configured Herdr origin")
    func originPolicy() throws {
        let origin = PaneGitWebOrigin(url: try #require(URL(string: "https://herdr.example.test")))

        #expect(origin.contains(try #require(URL(string: "https://herdr.example.test/herdr-web/"))))
        #expect(origin.contains(try #require(URL(string: "https://herdr.example.test:443/api/v1/panes/p1/git"))))
        #expect(!origin.contains(try #require(URL(string: "http://herdr.example.test/herdr-web/"))))
        #expect(!origin.contains(try #require(URL(string: "https://attacker.example/herdr-web/"))))
    }

    @Test("Loopback and same-machine harnesses count as local")
    func hostIsLocal() throws {
        let loopback = try #require(URL(string: "http://localhost:9092"))
        let loopbackIP = try #require(URL(string: "http://127.0.0.1:9092"))
        let remote = try #require(URL(string: "http://work-mac.tailnet.example:9092"))
        #expect(PaneGitWebDocument.harnessRunsOnThisMachine(loopback))
        #expect(PaneGitWebDocument.harnessRunsOnThisMachine(loopbackIP))
        #expect(!PaneGitWebDocument.harnessRunsOnThisMachine(remote))

        let hostName = ProcessInfo.processInfo.hostName.lowercased()
        let labels = hostName.split(separator: ".")
        guard let firstLabel = labels.first, !firstLabel.isEmpty else { return }
        let short = String(firstLabel)
        let byShort = try #require(URL(string: "http://" + short + ":9092"))
        let byLocal = try #require(URL(string: "http://" + short + ".local:9092"))
        let byFullName = try #require(URL(string: "http://" + hostName + ":9092"))
        let byTailnet = try #require(URL(string: "http://some-other-mac.tailnet.example:9092"))
        let byOwnTailnet = try #require(URL(string: "http://" + short + ".tailnet.example:9092"))
        #expect(PaneGitWebDocument.harnessRunsOnThisMachine(byShort))
        #expect(PaneGitWebDocument.harnessRunsOnThisMachine(byLocal))
        #expect(PaneGitWebDocument.harnessRunsOnThisMachine(byFullName))
        // First-label matches stay local even under dotted tailnet names…
        #expect(PaneGitWebDocument.harnessRunsOnThisMachine(byOwnTailnet))
        // …but a different machine's tailnet name is remote.
        #expect(!PaneGitWebDocument.harnessRunsOnThisMachine(byTailnet))
    }
}
