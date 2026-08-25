import Foundation
import os

struct HerdrHangReporter {
    struct IncidentHandle: Sendable {
        let url: URL
    }

    private let hangsDirectory: URL
    private let maxReports: Int

    init(hangsDirectory: URL = HerdrHangReporter.defaultHangsDirectory(), maxReports: Int = 20) {
        self.hangsDirectory = hangsDirectory
        self.maxReports = maxReports
    }

    static func defaultHangsDirectory() -> URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Herdr/hangs", isDirectory: true)
    }

    func finalizeStaleReportsAndPrune() {
        guard ensureDirectory() else { return }
        let fileManager = FileManager.default
        let reports = hangReportURLs(fileManager: fileManager)
        for report in reports {
            guard let contents = try? String(contentsOf: report, encoding: .utf8),
                  !contents.contains("RECOVERED after"),
                  !contents.contains("PROCESS TERMINATED DURING THIS HANG") else {
                continue
            }
            append("\nPROCESS TERMINATED DURING THIS HANG (force quit or kill)\n", to: report)
        }

        let excessCount = reports.count - maxReports
        guard excessCount > 0 else { return }
        for report in reports.prefix(excessCount) {
            try? fileManager.removeItem(at: report)
        }
    }

    func beginIncident(processStartedAt: Date) -> IncidentHandle? {
        guard ensureDirectory() else { return nil }
        let now = Date()
        let url = nextAvailableReportURL(startingAt: now)
        let fileManager = FileManager.default
        guard fileManager.createFile(atPath: url.path, contents: nil) else { return nil }

        let info = Bundle.main.infoDictionary
        let shortVersion = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let buildVersion = info?["CFBundleVersion"] as? String ?? "unknown"
        let header = """
        STATUS: INPROGRESS

        App: \(shortVersion) (\(buildVersion))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Process started: \(Self.iso8601Timestamp(processStartedAt))
        Incident started: \(Self.iso8601Timestamp(now))
        """
        append("\(header)\n", to: url)
        return IncidentHandle(url: url)
    }

    func appendSample(
        to incident: IncidentHandle,
        stallSoFar: Duration,
        mainThreadSample: HerdrPerfDiagnostics.MainThreadSample?,
        footprintMB: Int,
        terminalBacklog: Int,
        piBacklog: Int,
        checkpoints: [HerdrPerfDiagnostics.CheckpointSnapshot]
    ) {
        var lines = ["", "---", "Stall so far: \(Self.oneDecimal(Self.seconds(stallSoFar)))s"]
        if let mainThreadSample {
            lines.append(
                "Main thread CPU: \(Self.oneDecimal(mainThreadSample.cpuPercent))%  run-state: \(mainThreadSample.runState)  swapped: \(mainThreadSample.isSwapped)"
            )
        } else {
            lines.append("Main thread: no sample available")
        }
        lines.append("Footprint: \(footprintMB) MB")
        lines.append("Terminal backlog: \(terminalBacklog)  Pi backlog: \(piBacklog)")
        lines.append("Checkpoints (oldest first):")
        lines.append(contentsOf: checkpoints.map {
            "  \(Self.oneDecimal(Self.seconds($0.age)))s ago  \($0.name)"
        })
        lines.append("Backtrace:")
        if let mainThreadSample {
            lines.append(contentsOf: mainThreadSample.frames.enumerated().map { index, frame in
                let address = String(format: "%016llx", frame.address)
                let offset = String(format: "%llx", frame.offset)
                return "  #\(index)  0x\(address)  \(frame.imageName ?? "???") + 0x\(offset)  \(frame.symbolName ?? "???")"
            })
        } else {
            lines.append("  no sample available")
        }
        append("\(lines.joined(separator: "\n"))\n", to: incident.url)
    }

    func recordRecovery(of incident: IncidentHandle, after duration: Duration) {
        append("\n---\nRECOVERED after \(Self.oneDecimal(Self.seconds(duration)))s\n", to: incident.url)
    }

    private func ensureDirectory() -> Bool {
        do {
            try FileManager.default.createDirectory(at: hangsDirectory, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    private func hangReportURLs(fileManager: FileManager) -> [URL] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: hangsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { $0.lastPathComponent.hasPrefix("hang-") && $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func nextAvailableReportURL(startingAt date: Date) -> URL {
        var candidateDate = date
        var candidate = hangsDirectory.appendingPathComponent("hang-\(Self.reportTimestamp(candidateDate)).txt")
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidateDate.addTimeInterval(1)
            candidate = hangsDirectory.appendingPathComponent("hang-\(Self.reportTimestamp(candidateDate)).txt")
        }
        return candidate
    }

    private func append(_ text: String, to url: URL) {
        guard let data = text.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return }
        }
        guard let handle = FileHandle(forWritingAtPath: url.path) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return
        }
    }

    private static func reportTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    static func iso8601Timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

struct HerdrVitalsLog: Sendable {
    private let directory: URL
    private let maxBytes: Int
    private let lock = OSAllocatedUnfairLock<Void>(initialState: ())

    init(
        directory: URL = HerdrHangReporter.defaultHangsDirectory().deletingLastPathComponent(),
        maxBytes: Int = 512 * 1024
    ) {
        self.directory = directory
        self.maxBytes = maxBytes
    }

    func appendLine(_ line: String) {
        guard let data = "\(line)\n".data(using: .utf8) else { return }
        lock.withLock { _ in
            let fileManager = FileManager.default
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return
            }

            let currentURL = directory.appendingPathComponent("vitals.log")
            let rotatedURL = directory.appendingPathComponent("vitals.log.1")
            let currentSize = (try? currentURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if currentSize > 0, currentSize + data.count > maxBytes {
                try? fileManager.removeItem(at: rotatedURL)
                do {
                    try fileManager.moveItem(at: currentURL, to: rotatedURL)
                } catch {
                    return
                }
            }
            append(data, to: currentURL, fileManager: fileManager)
        }
    }

    static func timestampedLine(_ fields: String) -> String {
        "\(HerdrHangReporter.iso8601Timestamp(Date())) \(fields)"
    }

    private func append(_ data: Data, to url: URL, fileManager: FileManager) {
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: nil) else { return }
        }
        guard let handle = FileHandle(forWritingAtPath: url.path) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return
        }
    }
}
