import Foundation

struct HarnessServerSource: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var urlString: String

    init(id: String? = nil, name: String, urlString: String) {
        let normalizedURL = HarnessAPI.normalizedBaseURL(urlString)
        self.id = id ?? Self.id(for: normalizedURL)
        self.name = Self.normalizedName(name, urlString: normalizedURL)
        self.urlString = normalizedURL
    }

    static func id(for normalizedURL: String) -> String {
        "url:\(normalizedURL)"
    }

    static func normalizedName(_ name: String, urlString: String) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? fallbackName(for: urlString) : trimmedName
    }

    static func fallbackName(for urlString: String) -> String {
        guard let url = URL(string: urlString),
              let host = url.host,
              !host.isEmpty else {
            return "CMUX Server"
        }

        if let port = url.port {
            return "\(host):\(port)"
        }
        return host
    }
}
