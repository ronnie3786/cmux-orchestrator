import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Herdr hang reporter")
struct HerdrHangReporterTests {
    @Test("Hang reports record their lifecycle and samples")
    func lifecycle() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reporter = HerdrHangReporter(hangsDirectory: directory)
        let incident = try #require(reporter.beginIncident(processStartedAt: Date(timeIntervalSince1970: 0)))
        let sample = HerdrPerfDiagnostics.MainThreadSample(
            cpuPercent: 42.5,
            runState: 3,
            isSwapped: false,
            frames: [
                .init(address: 0x1234, imageName: "Herdr", imageBase: 0x1000, offset: 0x234, symbolName: "work()")
            ]
        )
        reporter.appendSample(
            to: incident,
            stallSoFar: .seconds(2),
            mainThreadSample: sample,
            footprintMB: 123,
            terminalBacklog: 4,
            piBacklog: 5,
            checkpoints: [.init(name: "test.checkpoint", age: .seconds(1))]
        )
        reporter.appendSample(
            to: incident,
            stallSoFar: .seconds(10),
            mainThreadSample: nil,
            footprintMB: 124,
            terminalBacklog: 6,
            piBacklog: 7,
            checkpoints: []
        )
        reporter.recordRecovery(of: incident, after: .seconds(12))

        let contents = try String(contentsOf: incident.url, encoding: .utf8)
        #expect(contents.contains("STATUS: INPROGRESS"))
        #expect(contents.contains("Stall so far: 2.0s"))
        #expect(contents.contains("Main thread CPU: 42.5%"))
        #expect(contents.contains("Main thread: no sample available"))
        #expect(contents.contains("RECOVERED after 12.0s"))
    }

    @Test("Incomplete reports are marked as terminated")
    func finalizeIncompleteReport() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = directory.appendingPathComponent("hang-20260101-010101.txt")
        try "STATUS: INPROGRESS\n\nApp: test\n".write(to: report, atomically: true, encoding: .utf8)

        HerdrHangReporter(hangsDirectory: directory).finalizeStaleReportsAndPrune()

        let contents = try String(contentsOf: report, encoding: .utf8)
        #expect(contents.contains("PROCESS TERMINATED DURING THIS HANG"))
    }

    @Test("Pruning retains the newest reports")
    func prune() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<25 {
            let name = String(format: "hang-20260101-%06d.txt", index)
            try "STATUS: INPROGRESS\nRECOVERED after 1.0s\n".write(
                to: directory.appendingPathComponent(name),
                atomically: true,
                encoding: .utf8
            )
        }

        HerdrHangReporter(hangsDirectory: directory).finalizeStaleReportsAndPrune()

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(names.count == 20)
        #expect(names == (5..<25).map { String(format: "hang-20260101-%06d.txt", $0) })
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@Suite("Herdr vitals log")
struct HerdrVitalsLogTests {
    @Test("Vitals logs rotate before exceeding their limit")
    func rotation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vitals = HerdrVitalsLog(directory: directory, maxBytes: 200)

        vitals.appendLine(String(repeating: "a", count: 90))
        vitals.appendLine(String(repeating: "b", count: 90))
        vitals.appendLine(String(repeating: "c", count: 90))

        let rotated = try String(contentsOf: directory.appendingPathComponent("vitals.log.1"), encoding: .utf8)
        let current = try String(contentsOf: directory.appendingPathComponent("vitals.log"), encoding: .utf8)
        #expect(rotated.contains(String(repeating: "a", count: 90)))
        #expect(rotated.contains(String(repeating: "b", count: 90)))
        #expect(!rotated.contains(String(repeating: "c", count: 90)))
        #expect(current == "\(String(repeating: "c", count: 90))\n")
    }
}
