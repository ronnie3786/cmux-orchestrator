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
        bootstrapScript = Self.makeBootstrapScript(configuration: configuration)
        allowedOrigin = PaneGitWebOrigin(url: configuration.baseURL)
    }

    private static func makeBootstrapScript(configuration: ServerConfiguration) -> String {
        struct NativeConfiguration: Encodable {
            let token: String
            let serverUrl: String
        }

        let nativeConfiguration = NativeConfiguration(
            token: configuration.token,
            serverUrl: configuration.baseURL.absoluteString
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
