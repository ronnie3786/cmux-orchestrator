import Foundation

enum ServerSmokeRunner {
    static func run(port: Int) -> Int32 {
        guard let serverRoot = HarnessServerLocator.locateServerRoot() else {
            fputs("server-smoke failed: dashboard.py and cmux_harness/ not found\n", stderr)
            return 2
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", serverRoot.appendingPathComponent("dashboard.py").path, String(port)]
        process.currentDirectoryURL = serverRoot

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = serverRoot.path
        environment["PYTHONUNBUFFERED"] = "1"
        environment["CMUX_HARNESS_NO_BROWSER"] = "1"
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
        } catch {
            fputs("server-smoke failed to start: \(error.localizedDescription)\n", stderr)
            return 3
        }

        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        let statusURL = URL(string: "http://127.0.0.1:\(port)/api/status")!
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let data = try? Data(contentsOf: statusURL),
               let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               payload["workspaces"] != nil {
                print("server-smoke ok: \(statusURL.absoluteString)")
                return 0
            }
            Thread.sleep(forTimeInterval: 0.25)
        }

        let captured = String(data: output.fileHandleForReading.availableData, encoding: .utf8) ?? ""
        fputs("server-smoke failed: /api/status did not respond\n\(captured)\n", stderr)
        return 4
    }
}
