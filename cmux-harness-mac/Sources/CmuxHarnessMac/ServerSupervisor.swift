import AppKit
import Darwin
import Foundation

@MainActor
final class ServerSupervisor: ObservableObject {
    @Published var phase: ServerPhase = .stopped
    @Published var port: Int = 9091
    @Published var baseURLString: String = "http://localhost:9091/harness"
    @Published var status: HarnessStatus?
    @Published var network: NetworkResponse?
    @Published var recentOutput: [String] = []
    @Published var lastError: String?
    @Published var autoRestart = true

    private var process: Process?
    private var healthTask: Task<Void, Never>?
    private var outputHandles: [FileHandle] = []
    private let maxOutputLines = 120
    private var restartAttempts = 0
    private let maxRestartAttempts = 3

    deinit {
        if process?.isRunning == true {
            process?.terminate()
        }
    }

    var apiClient: HarnessAPIClient {
        HarnessAPIClient(baseURLString: baseURLString)
    }

    func start(port requestedPort: Int? = nil) {
        guard process == nil else { return }
        phase = .starting
        lastError = nil
        port = resolvedPort(preferredPort: requestedPort)
        baseURLString = "http://localhost:\(port)/harness"

        guard let serverRoot = HarnessServerLocator.locateServerRoot() else {
            phase = .unhealthy("Could not find dashboard.py")
            lastError = "Could not find dashboard.py. Set CMUX_HARNESS_REPO_ROOT or run from the repo checkout."
            return
        }

        let dashboard = serverRoot.appendingPathComponent("dashboard.py")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", dashboard.path, String(port)]
        proc.currentDirectoryURL = serverRoot
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = serverRoot.path
        environment["PYTHONUNBUFFERED"] = "1"
        environment["CMUX_HARNESS_NO_BROWSER"] = "1"
        proc.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        capture(stdout.fileHandleForReading, prefix: "server")
        capture(stderr.fileHandleForReading, prefix: "server")
        outputHandles = [stdout.fileHandleForReading, stderr.fileHandleForReading]

        proc.terminationHandler = { [weak self] terminated in
            Task { @MainActor in
                guard let self else { return }
                self.process = nil
                self.healthTask?.cancel()
                let reason = "Exited with status \(terminated.terminationStatus)"
                if self.phase != .stopped {
                    self.phase = .crashed(reason)
                    self.lastError = reason
                    self.appendOutput("server: \(reason)")
                    self.scheduleRestartIfNeeded()
                }
            }
        }

        do {
            try proc.run()
            process = proc
            appendOutput("server: started dashboard.py on port \(port)")
            startHealthPolling()
        } catch {
            phase = .crashed(error.localizedDescription)
            lastError = error.localizedDescription
            appendOutput("server: failed to start: \(error.localizedDescription)")
        }
    }

    func stop() {
        healthTask?.cancel()
        healthTask = nil
        let proc = process
        process = nil
        if proc?.isRunning == true {
            proc?.terminate()
        }
        phase = .stopped
        appendOutput("server: stopped")
    }

    func restart(port requestedPort: Int? = nil) {
        stop()
        start(port: requestedPort)
    }

    func openBrowserDashboard() {
        guard let url = URL(string: baseURLString) else { return }
        NSWorkspace.shared.open(url)
    }

    func copyIPhoneURL() {
        let urls = network?.urls
        let value = urls?.tailscaleHarness
            ?? urls?.detectedTailscaleHarness
            ?? urls?.lanHarness?.first
            ?? baseURLString
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func openCmux() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/cmux.app"), configuration: .init())
    }

    private func startHealthPolling() {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollHealth()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func pollHealth() async {
        let client = apiClient
        do {
            async let status = client.status()
            async let network = client.network()
            self.status = try await status
            self.network = try? await network
            self.phase = .running
            self.lastError = nil
            self.restartAttempts = 0
        } catch {
            if process?.isRunning == true {
                phase = .unhealthy(error.localizedDescription)
            } else if process == nil {
                phase = .stopped
            }
            lastError = error.localizedDescription
        }
    }

    private func capture(_ handle: FileHandle, prefix: String) {
        handle.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                text.split(whereSeparator: \.isNewline).forEach { line in
                    self?.appendOutput("\(prefix): \(line)")
                }
            }
        }
    }

    private func appendOutput(_ line: String) {
        recentOutput.append(line)
        if recentOutput.count > maxOutputLines {
            recentOutput.removeFirst(recentOutput.count - maxOutputLines)
        }
    }

    private func resolvedPort(preferredPort: Int? = nil) -> Int {
        if let raw = ProcessInfo.processInfo.environment["CMUX_HARNESS_PORT"],
           let value = Int(raw),
           value > 0 {
            return firstAvailablePort(startingAt: value)
        }
        return firstAvailablePort(startingAt: preferredPort ?? 9091)
    }

    private func scheduleRestartIfNeeded() {
        guard autoRestart, restartAttempts < maxRestartAttempts else { return }
        restartAttempts += 1
        let nextPort = port
        appendOutput("server: restarting in 1s (attempt \(restartAttempts)/\(maxRestartAttempts))")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await MainActor.run {
                guard let self, self.process == nil, self.phase != .stopped else { return }
                self.start(port: nextPort)
            }
        }
    }

    private func firstAvailablePort(startingAt preferredPort: Int) -> Int {
        let start = max(1, min(preferredPort, 65_535))
        for candidate in start...min(start + 20, 65_535) {
            if isPortAvailable(candidate) {
                return candidate
            }
        }
        return start
    }

    private func isPortAvailable(_ port: Int) -> Bool {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { return true }
        defer { close(socketDescriptor) }

        var reuse: Int32 = 1
        setsockopt(socketDescriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(socketDescriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 {
            return true
        }
        return errno != EADDRINUSE
    }
}
