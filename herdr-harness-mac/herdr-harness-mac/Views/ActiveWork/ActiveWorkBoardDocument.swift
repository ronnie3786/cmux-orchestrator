import Foundation

struct ActiveWorkBoardDocument: Equatable {
    let url: URL
    let bootstrapScript: String
    let allowedOrigin: ActiveWorkBoardOrigin

    init(configuration: ServerConfiguration) {
        let pageURL = configuration.baseURL.appending(
            path: "board",
            directoryHint: .isDirectory
        )
        var pageComponents = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)
        pageComponents?.queryItems = [
            URLQueryItem(name: "embed", value: "1"),
        ]

        url = pageComponents?.url ?? pageURL
        bootstrapScript = Self.makeBootstrapScript(configuration: configuration)
        allowedOrigin = ActiveWorkBoardOrigin(url: configuration.baseURL)
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
