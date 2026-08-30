import Foundation

struct ActiveWorkBoardOrigin: Equatable {
    let scheme: String?
    let host: String?
    let port: Int?

    init(url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        scheme = components?.scheme?.lowercased()
        host = components?.host?.lowercased()
        port = Self.effectivePort(for: components)
    }

    func contains(_ url: URL) -> Bool {
        if url.absoluteString == "about:blank" { return true }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return components?.scheme?.lowercased() == scheme
            && components?.host?.lowercased() == host
            && Self.effectivePort(for: components) == port
    }

    private static func effectivePort(for components: URLComponents?) -> Int? {
        if let port = components?.port { return port }
        return switch components?.scheme?.lowercased() {
        case "http": 80
        case "https": 443
        default: nil
        }
    }
}
