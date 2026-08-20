import Foundation

struct ServerConfiguration: Equatable, Sendable {
    let baseURL: URL
    let token: String

    init?(urlString: String, token: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty
        else { return nil }

        if scheme == "http" {
            let localHosts = ["localhost", "127.0.0.1", "::1"]
            let normalizedHost = host
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .lowercased()
            guard localHosts.contains(normalizedHost) else { return nil }
        }

        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { return nil }
        baseURL = url
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
