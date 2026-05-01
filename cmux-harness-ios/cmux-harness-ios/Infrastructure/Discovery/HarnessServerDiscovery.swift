import Foundation

enum HarnessServerDiscovery {
    static func discover(timeout: TimeInterval = 4) async -> [DiscoveredHarnessServer] {
        await withCheckedContinuation { continuation in
            let browser = BonjourHarnessBrowser(timeout: timeout) { servers in
                continuation.resume(returning: servers)
            }
            browser.start()
        }
    }
}

private final class BonjourHarnessBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let timeout: TimeInterval
    private let completion: ([DiscoveredHarnessServer]) -> Void
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var servers: [DiscoveredHarnessServer] = []
    private var didFinish = false

    init(timeout: TimeInterval, completion: @escaping ([DiscoveredHarnessServer]) -> Void) {
        self.timeout = timeout
        self.completion = completion
        super.init()
    }

    func start() {
        browser.delegate = self
        browser.searchForServices(ofType: "_cmux-harness._tcp.", inDomain: "local.")
        Task {
            let nanoseconds = UInt64(max(0.5, timeout) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            await MainActor.run {
                self.finish()
            }
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: min(timeout, 3))
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard sender.port > 0 else { return }
        let host = normalizedHost(sender.hostName) ?? normalizedServiceName(sender.name)
        guard !host.isEmpty else { return }
        let urlString = "http://\(host):\(sender.port)/harness"
        let server = DiscoveredHarnessServer(
            name: sender.name.isEmpty ? "cmux harness" : sender.name,
            urlString: urlString,
            source: .lan
        )
        if !servers.contains(where: { $0.urlString == server.urlString }) {
            servers.append(server)
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        finish()
    }

    private func normalizedHost(_ hostName: String?) -> String? {
        guard var hostName = hostName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hostName.isEmpty else {
            return nil
        }
        while hostName.hasSuffix(".") {
            hostName.removeLast()
        }
        return hostName
    }

    private func normalizedServiceName(_ name: String) -> String {
        let safe = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
        return safe.isEmpty ? "" : "\(safe).local"
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        browser.stop()
        services.forEach { $0.stop() }
        completion(servers)
    }
}
