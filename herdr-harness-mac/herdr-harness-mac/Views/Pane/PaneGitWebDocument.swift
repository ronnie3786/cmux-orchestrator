import Foundation

struct PaneGitWebDocument: Equatable {
    let url: URL
    let bootstrapScript: String
    let allowedOrigin: PaneGitWebOrigin

    init(
        configuration: ServerConfiguration,
        workspaceID: String,
        paneID: String
    ) {
        let pageURL = configuration.baseURL.appending(
            path: "herdr-web",
            directoryHint: .isDirectory
        )
        var pageComponents = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)
        var routeComponents = URLComponents()
        routeComponents.queryItems = [
            URLQueryItem(name: "ws", value: workspaceID),
            URLQueryItem(name: "pane", value: paneID),
            URLQueryItem(name: "view", value: "git"),
            URLQueryItem(name: "embed", value: "1"),
        ]
        pageComponents?.percentEncodedFragment = routeComponents.percentEncodedQuery

        url = pageComponents?.url ?? pageURL
        bootstrapScript = Self.makeBootstrapScript(
            configuration: configuration,
            hostIsLocal: Self.harnessRunsOnThisMachine(configuration.baseURL)
        )
        allowedOrigin = PaneGitWebOrigin(url: configuration.baseURL)
    }

    /// True when the harness this document loads from runs on the Mac in
    /// front of the user — loopback URLs and this Mac's own hostnames count.
    static func harnessRunsOnThisMachine(_ url: URL) -> Bool {
        guard let rawHost = url.host(percentEncoded: false)?.lowercased() else { return false }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return true }

        let localNames = Self.localHostNames()
        if localNames.contains(host) { return true }
        // Tailnet-style URLs may name the machine with a dotted suffix.
        let firstLabel = host.split(separator: ".").first.map(String.init) ?? host
        return localNames.contains(firstLabel)
    }

    private static func localHostNames() -> Set<String> {
        var names: Set<String> = []
        let hostName = ProcessInfo.processInfo.hostName.lowercased()
        guard !hostName.isEmpty else { return names }
        names.insert(hostName)
        let labels = hostName.split(separator: ".")
        if let first = labels.first {
            let short = String(first)
            names.insert(short)
            names.insert("\(short).local")
        }
        return names
    }

    private static func makeBootstrapScript(
        configuration: ServerConfiguration,
        hostIsLocal: Bool
    ) -> String {
        struct NativeConfiguration: Encodable {
            let token: String
            let serverUrl: String
            let hostIsLocal: Bool
        }

        let nativeConfiguration = NativeConfiguration(
            token: configuration.token,
            serverUrl: configuration.baseURL.absoluteString,
            hostIsLocal: hostIsLocal
        )
        let data = try? JSONEncoder().encode(nativeConfiguration)
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        Object.defineProperty(window, "__HERDR_NATIVE_CONFIG__", {
          value: Object.freeze(\(json)),
          writable: false,
          configurable: false
        });
        """
    }
}