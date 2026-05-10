import Foundation

enum HarnessServerLocator {
    static func locateServerRoot() -> URL? {
        let env = ProcessInfo.processInfo.environment["CMUX_HARNESS_REPO_ROOT"] ?? ""
        let current = FileManager.default.currentDirectoryPath
        let candidates = [
            env,
            current,
            URL(fileURLWithPath: current).deletingLastPathComponent().path,
            Bundle.main.resourceURL?.path ?? "",
            Bundle.main.resourceURL?.appendingPathComponent("Python").path ?? ""
        ].filter { !$0.isEmpty }

        for candidate in candidates {
            let root = URL(fileURLWithPath: candidate)
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("dashboard.py").path),
               FileManager.default.fileExists(atPath: root.appendingPathComponent("cmux_harness").path) {
                return root
            }
        }
        return nil
    }
}
