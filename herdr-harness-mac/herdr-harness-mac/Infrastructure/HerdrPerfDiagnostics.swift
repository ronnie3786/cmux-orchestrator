import Darwin
import Foundation
import os

/// Lightweight, always-on breadcrumbs for diagnosing work that starves the UI.
/// The watchdog deliberately lives off the main actor so a stuck executor can
/// report itself instead of waiting behind the work it is measuring.
enum HerdrPerfDiagnostics {
    private static let logger = Logger(subsystem: "dev.ronnierocha.herdr-harness", category: "perf")
    private static let state = SharedState()
    private static let processStartedAt = Date()
    private static let vitalsLog = HerdrVitalsLog()

    static let streamBacklog = StreamBacklog()

    static func start() {
        let shouldStart = state.lock.withLock { value in
            guard !value.started else { return false }
            value.started = true
            return true
        }
        guard shouldStart else { return }
        _ = processStartedAt

        HerdrHangReporter().finalizeStaleReportsAndPrune()

        if Thread.isMainThread {
            captureMainThreadInfo()
        } else {
            DispatchQueue.main.sync {
                captureMainThreadInfo()
            }
        }

        let thread = Thread { runWatchdog() }
        thread.name = "herdr.perf.watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }

    static func checkpoint(_ name: StaticString) {
        let now = ContinuousClock().now
        state.lock.withLock { $0.recordCheckpoint(name, at: now) }
    }

    struct CheckpointSnapshot: Sendable {
        let name: String
        let age: Duration
    }

    static func checkpointRingSnapshot(now: ContinuousClock.Instant) -> [CheckpointSnapshot] {
        state.lock.withLock { values in
            guard values.checkpointCount > 0 else { return [] }

            var snapshots: [CheckpointSnapshot] = []
            snapshots.reserveCapacity(values.checkpointCount)
            let firstIndex = values.checkpointCount == WatchdogValues.checkpointCapacity
                ? values.nextCheckpointIndex
                : 0
            for offset in 0..<values.checkpointCount {
                let index = (firstIndex + offset) % WatchdogValues.checkpointCapacity
                let checkpoint = values.checkpoints[index]
                guard let recordedAt = checkpoint.recordedAt else { continue }
                snapshots.append(
                    CheckpointSnapshot(
                        name: String(describing: checkpoint.name),
                        age: recordedAt.duration(to: now)
                    )
                )
            }
            return snapshots
        }
    }

    static func stallDuration(
        now: ContinuousClock.Instant,
        pingSentAt: ContinuousClock.Instant?,
        acked: Bool
    ) -> Duration? {
        guard !acked, let pingSentAt else { return nil }
        return pingSentAt.duration(to: now)
    }

    static func currentFootprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint / (1024 * 1024))
    }

    final class StreamBacklog: Sendable {
        enum Kind: Int, CaseIterable, Sendable {
            case terminal
            case pi
        }

        private struct Values: Sendable {
            var counts = Array(repeating: 0, count: Kind.allCases.count)
            var lastWarningAt = Array<Date?>(repeating: nil, count: Kind.allCases.count)
            var lastErrorAt = Array<Date?>(repeating: nil, count: Kind.allCases.count)
        }

        private let lock = OSAllocatedUnfairLock<Values>(initialState: Values())

        func noteYielded(_ kind: Kind) {
            let result = lock.withLock { values -> (backlog: Int, level: BacklogLogLevel?) in
                let index = kind.rawValue
                values.counts[index] += 1
                let now = Date.now
                if values.counts[index] > 1024,
                   values.lastErrorAt[index].map({ now.timeIntervalSince($0) >= 10 }) ?? true {
                    values.lastErrorAt[index] = now
                    return (values.counts[index], .error)
                }
                if values.counts[index] > 64,
                   values.lastWarningAt[index].map({ now.timeIntervalSince($0) >= 10 }) ?? true {
                    values.lastWarningAt[index] = now
                    return (values.counts[index], .warning)
                }
                return (values.counts[index], nil)
            }
            if result.level == .error {
                logger.error("stream backlog high kind=\(String(describing: kind), privacy: .public) backlog=\(result.backlog)")
            } else if result.level != nil {
                logger.warning("stream backlog high kind=\(String(describing: kind), privacy: .public) backlog=\(result.backlog)")
            }
        }

        private enum BacklogLogLevel: Sendable, Equatable {
            case warning
            case error
        }

        func noteConsumed(_ kind: Kind) {
            lock.withLock { values in
                let index = kind.rawValue
                values.counts[index] = max(0, values.counts[index] - 1)
            }
        }

        func noteOverflow(_ kind: Kind) {
            let backlog = lock.withLock { values -> Int in
                let index = kind.rawValue
                let backlog = values.counts[index]
                values.counts[index] = 0
                return backlog
            }
            logger.error("stream backlog overflow kind=\(String(describing: kind), privacy: .public) backlog=\(backlog)")
            HerdrPerfDiagnostics.vitalsLog.appendLine(
                HerdrVitalsLog.timestampedLine(
                    "event=backlogOverflow kind=\(String(describing: kind)) backlog=\(backlog)"
                )
            )
        }

        func current(_ kind: Kind) -> Int {
            lock.withLock { $0.counts[kind.rawValue] }
        }

        func reset(_ kind: Kind) {
            lock.withLock { values in
                values.counts[kind.rawValue] = 0
            }
        }
    }

    struct MainThreadSample: Sendable {
        struct Frame: Sendable {
            let address: UInt64
            let imageName: String?
            let imageBase: UInt64
            let offset: UInt64
            let symbolName: String?
        }

        let cpuPercent: Double
        let runState: Int32
        let isSwapped: Bool
        let frames: [Frame]
    }

    private struct Checkpoint: Sendable {
        var name: StaticString = ""
        var recordedAt: ContinuousClock.Instant?
    }

    private struct MainThreadInfo: Sendable {
        let port: mach_port_t
        let stackLow: UInt64
        let stackHigh: UInt64
    }

    private struct WatchdogValues: Sendable {
        static let checkpointCapacity = 64

        var started = false
        var acknowledgedSequence: UInt64 = 0
        var checkpoints = Array(repeating: Checkpoint(), count: checkpointCapacity)
        var nextCheckpointIndex = 0
        var checkpointCount = 0
        var mainThreadInfo: MainThreadInfo?

        mutating func recordCheckpoint(_ name: StaticString, at now: ContinuousClock.Instant) {
            checkpoints[nextCheckpointIndex] = Checkpoint(name: name, recordedAt: now)
            nextCheckpointIndex = (nextCheckpointIndex + 1) % Self.checkpointCapacity
            checkpointCount = min(checkpointCount + 1, Self.checkpointCapacity)
        }

        var mostRecentCheckpointName: String {
            guard checkpointCount > 0 else { return "none" }
            let index = (nextCheckpointIndex + Self.checkpointCapacity - 1) % Self.checkpointCapacity
            return String(describing: checkpoints[index].name)
        }
    }

    private final class SharedState: Sendable {
        let lock = OSAllocatedUnfairLock<WatchdogValues>(initialState: WatchdogValues())
        let sampleBuffer = OSAllocatedUnfairLock<[UInt64]>(initialState: Array(repeating: 0, count: 128))

        func acknowledge(_ sequence: UInt64) {
            lock.withLock { $0.acknowledgedSequence = max($0.acknowledgedSequence, sequence) }
        }
    }

    private static func runWatchdog() {
        let clock = ContinuousClock()
        var sequence: UInt64 = 0
        var outstanding: (sequence: UInt64, sentAt: ContinuousClock.Instant)?
        var stalledSince: ContinuousClock.Instant?
        var lastStallLogAt: ContinuousClock.Instant?
        var lastFootprintAt = clock.now
        let hangReporter = HerdrHangReporter()
        var activeIncident: HerdrHangReporter.IncidentHandle?
        var nextSampleThreshold: Duration = .seconds(2)
        var sampleCount = 0

        while true {
            let now = clock.now
            if let priorPing = outstanding {
                let acknowledged = state.lock.withLock { $0.acknowledgedSequence >= priorPing.sequence }
                if acknowledged {
                    if let stallStartedAt = stalledSince {
                        logger.notice("main actor recovered after \(seconds(stallStartedAt.duration(to: now)), format: .fixed(precision: 1))s")
                        let duration = stallStartedAt.duration(to: now)
                        if let activeIncident {
                            hangReporter.recordRecovery(of: activeIncident, after: duration)
                        }
                        vitalsLog.appendLine(
                            HerdrVitalsLog.timestampedLine(
                                "event=recovery duration=\(String(format: "%.1f", seconds(duration)))s"
                            )
                        )
                        stalledSince = nil
                        lastStallLogAt = nil
                        activeIncident = nil
                        nextSampleThreshold = .seconds(2)
                        sampleCount = 0
                    }
                    outstanding = nil
                } else if let duration = stallDuration(now: now, pingSentAt: priorPing.sentAt, acked: false), duration >= .seconds(2) {
                    if stalledSince == nil {
                        stalledSince = priorPing.sentAt
                        activeIncident = hangReporter.beginIncident(processStartedAt: processStartedAt)
                        let checkpoint = state.lock.withLock(\.mostRecentCheckpointName)
                        let terminalBacklog = streamBacklog.current(.terminal)
                        let piBacklog = streamBacklog.current(.pi)
                        let footprint = currentFootprintMB()
                        vitalsLog.appendLine(
                            HerdrVitalsLog.timestampedLine(
                                "event=stallStart lastCheckpoint=\(checkpoint) terminalBacklog=\(terminalBacklog) piBacklog=\(piBacklog) footprintMB=\(footprint)"
                            )
                        )
                    }
                    if let activeIncident, duration >= nextSampleThreshold, sampleCount < 10 {
                        let mainThreadSample = captureMainThreadSample()
                        let footprint = currentFootprintMB()
                        let terminalBacklog = streamBacklog.current(.terminal)
                        let piBacklog = streamBacklog.current(.pi)
                        let checkpoints = checkpointRingSnapshot(now: now)
                        hangReporter.appendSample(
                            to: activeIncident,
                            stallSoFar: duration,
                            mainThreadSample: mainThreadSample,
                            footprintMB: footprint,
                            terminalBacklog: terminalBacklog,
                            piBacklog: piBacklog,
                            checkpoints: checkpoints
                        )
                        sampleCount += 1
                        if nextSampleThreshold == .seconds(2) {
                            nextSampleThreshold = .seconds(10)
                        } else if nextSampleThreshold == .seconds(10) {
                            nextSampleThreshold = .seconds(30)
                        } else {
                            nextSampleThreshold += .seconds(60)
                        }
                    }
                    if lastStallLogAt.map({ $0.duration(to: now) >= .seconds(5) }) ?? true {
                        let checkpoint = state.lock.withLock(\.mostRecentCheckpointName)
                        logger.error(
                            "main actor unresponsive for \(seconds(duration), format: .fixed(precision: 1))s lastCheckpoint=\(checkpoint, privacy: .public) terminalBacklog=\(streamBacklog.current(.terminal)) piBacklog=\(streamBacklog.current(.pi)) footprintMB=\(currentFootprintMB())"
                        )
                        lastStallLogAt = now
                    }
                }
            }

            if lastFootprintAt.duration(to: now) >= .seconds(30) {
                let checkpoint = state.lock.withLock(\.mostRecentCheckpointName)
                let mainThreadPort = state.lock.withLock(\.mainThreadInfo)?.port
                let basicInfo = mainThreadPort.flatMap { readBasicInfo(from: $0) }
                let mainCPUText = basicInfo.map { String(format: "%.1f", $0.cpuPercent) } ?? "n/a"
                let runStateText = basicInfo.map { String($0.runState) } ?? "n/a"
                logger.info(
                    "footprint=\(currentFootprintMB())MB terminalBacklog=\(streamBacklog.current(.terminal)) piBacklog=\(streamBacklog.current(.pi)) checkpoint=\(checkpoint, privacy: .public)"
                )
                vitalsLog.appendLine(
                    HerdrVitalsLog.timestampedLine(
                        "event=periodic footprintMB=\(currentFootprintMB()) mainCPU=\(mainCPUText) runState=\(runStateText) terminalBacklog=\(streamBacklog.current(.terminal)) piBacklog=\(streamBacklog.current(.pi)) checkpoint=\(checkpoint)"
                    )
                )
                lastFootprintAt = now
            }

            if outstanding == nil {
                sequence &+= 1
                let sentAt = clock.now
                outstanding = (sequence, sentAt)
                let sharedState = state
                let pingSequence = sequence
                Task { @MainActor in
                    sharedState.acknowledge(pingSequence)
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func captureMainThreadInfo() {
        let thread = pthread_self()
        let stackHigh = UInt64(UInt(bitPattern: pthread_get_stackaddr_np(thread)))
        let stackSize = UInt64(pthread_get_stacksize_np(thread))
        guard stackSize <= stackHigh else { return }

        let mainThreadInfo = MainThreadInfo(
            port: pthread_mach_thread_np(thread),
            stackLow: stackHigh - stackSize,
            stackHigh: stackHigh
        )
        state.lock.withLock { $0.mainThreadInfo = mainThreadInfo }
    }

    static func captureMainThreadSample() -> MainThreadSample? {
        guard let mainThreadInfo = state.lock.withLock(\.mainThreadInfo) else { return nil }
        return state.sampleBuffer.withLock { buffer in
            buffer.withUnsafeMutableBufferPointer { scratch in
                guard let sample = captureSuspendedThread(
                    port: mainThreadInfo.port,
                    stackLow: mainThreadInfo.stackLow,
                    stackHigh: mainThreadInfo.stackHigh,
                    into: scratch
                ) else {
                    return nil
                }
                return symbolicate(
                    addresses: UnsafeBufferPointer(scratch),
                    count: sample.frameCount,
                    cpuPercent: sample.cpuPercent,
                    runState: sample.runState,
                    isSwapped: sample.isSwapped
                )
            }
        }
    }

    @inline(never)
    static func captureCurrentThreadSample(maxFrames: Int = 128) -> MainThreadSample? {
        #if arch(arm64)
        let thread = pthread_self()
        let stackHigh = UInt64(UInt(bitPattern: pthread_get_stackaddr_np(thread)))
        let stackSize = UInt64(pthread_get_stacksize_np(thread))
        guard stackSize <= stackHigh else { return nil }

        var addresses = Array(repeating: UInt64(0), count: min(max(maxFrames, 1), 128))
        return addresses.withUnsafeMutableBufferPointer { scratch in
            var framePointer: UInt = 0
            var programCounter: UInt = 0
            herdr_capture_backtrace_anchor(&framePointer, &programCounter)
            let frameCount = walkFramePointerChain(
                startFP: UInt64(framePointer),
                startPC: UInt64(programCounter),
                stackLow: stackHigh - stackSize,
                stackHigh: stackHigh,
                into: scratch
            )
            return symbolicate(
                addresses: UnsafeBufferPointer(scratch),
                count: frameCount,
                cpuPercent: 0,
                runState: 0,
                isSwapped: false
            )
        }
        #else
        return nil
        #endif
    }

    static func walkFramePointerChain(
        startFP: UInt64,
        startPC: UInt64,
        stackLow: UInt64,
        stackHigh: UInt64,
        into buffer: UnsafeMutableBufferPointer<UInt64>
    ) -> Int {
        #if arch(arm64)
        guard !buffer.isEmpty else { return 0 }
        buffer[0] = startPC
        let limit = min(buffer.count, 128)
        var frameCount = 1
        var framePointer = startFP

        while framePointer != 0, frameCount < limit {
            guard framePointer.isMultiple(of: 16),
                  framePointer >= stackLow,
                  framePointer <= stackHigh,
                  stackHigh - framePointer >= 16,
                  let frame = UnsafeRawPointer(bitPattern: UInt(framePointer)) else {
                break
            }

            let previousFramePointer = frame.load(as: UInt64.self)
            let returnAddress = frame.load(fromByteOffset: 8, as: UInt64.self)
            guard previousFramePointer > framePointer else { break }
            buffer[frameCount] = returnAddress
            frameCount += 1
            framePointer = previousFramePointer
        }
        return frameCount
        #else
        return 0
        #endif
    }

    private struct SuspendedThreadSample: Sendable {
        let cpuPercent: Double
        let runState: Int32
        let isSwapped: Bool
        let frameCount: Int
    }

    private static func captureSuspendedThread(
        port: mach_port_t,
        stackLow: UInt64,
        stackHigh: UInt64,
        into buffer: UnsafeMutableBufferPointer<UInt64>
    ) -> SuspendedThreadSample? {
        #if arch(arm64)
        guard let basicInfo = readBasicInfo(from: port) else { return nil }
        guard thread_suspend(port) == KERN_SUCCESS else { return nil }

        var registers = arm_thread_state64_t()
        var registerCount = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
        let registerResult = withUnsafeMutablePointer(to: &registers) {
            $0.withMemoryRebound(
                to: natural_t.self,
                capacity: MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size
            ) {
                thread_get_state(port, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &registerCount)
            }
        }
        guard registerResult == KERN_SUCCESS else {
            thread_resume(port)
            return nil
        }
        let frameCount = walkFramePointerChain(
            startFP: registers.__fp,
            startPC: registers.__pc,
            stackLow: stackLow,
            stackHigh: stackHigh,
            into: buffer
        )
        thread_resume(port)
        return SuspendedThreadSample(
            cpuPercent: basicInfo.cpuPercent,
            runState: basicInfo.runState,
            isSwapped: basicInfo.isSwapped,
            frameCount: frameCount
        )
        #else
        return nil
        #endif
    }

    private static func readBasicInfo(from port: mach_port_t) -> (cpuPercent: Double, runState: Int32, isSwapped: Bool)? {
        var basicInfo = thread_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &basicInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (
            cpuPercent: Double(basicInfo.cpu_usage) * 100 / Double(TH_USAGE_SCALE),
            runState: Int32(basicInfo.run_state),
            isSwapped: (basicInfo.flags & TH_FLAGS_SWAPPED) != 0
        )
    }

    private static func symbolicate(
        addresses: UnsafeBufferPointer<UInt64>,
        count: Int,
        cpuPercent: Double,
        runState: Int32,
        isSwapped: Bool
    ) -> MainThreadSample {
        var frames: [MainThreadSample.Frame] = []
        frames.reserveCapacity(count)
        for index in 0..<count {
            let address = addresses[index]
            var info = Dl_info()
            let resolved = UnsafeRawPointer(bitPattern: UInt(address)).map { dladdr($0, &info) != 0 } ?? false
            let imageBase = resolved ? UInt64(UInt(bitPattern: info.dli_fbase)) : 0
            frames.append(
                MainThreadSample.Frame(
                    address: address,
                    imageName: resolved ? info.dli_fname.map { String(cString: $0) } : nil,
                    imageBase: imageBase,
                    offset: address >= imageBase ? address - imageBase : 0,
                    symbolName: resolved ? info.dli_sname.map { String(cString: $0) } : nil
                )
            )
        }
        return MainThreadSample(
            cpuPercent: cpuPercent,
            runState: runState,
            isSwapped: isSwapped,
            frames: frames
        )
    }
}
