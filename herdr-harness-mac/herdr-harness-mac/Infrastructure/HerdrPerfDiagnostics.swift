import Darwin
import Foundation
import os

/// Lightweight, always-on breadcrumbs for diagnosing work that starves the UI.
/// The watchdog deliberately lives off the main actor so a stuck executor can
/// report itself instead of waiting behind the work it is measuring.
enum HerdrPerfDiagnostics {
    private static let logger = Logger(subsystem: "dev.ronnierocha.herdr-harness", category: "perf")
    private static let state = SharedState()

    static let streamBacklog = StreamBacklog()

    static func start() {
        let shouldStart = state.lock.withLock { value in
            guard !value.started else { return false }
            value.started = true
            return true
        }
        guard shouldStart else { return }

        let thread = Thread { runWatchdog() }
        thread.name = "herdr.perf.watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }

    static func checkpoint(_ name: StaticString) {
        state.lock.withLock { $0.lastCheckpoint = String(describing: name) }
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
        }

        func current(_ kind: Kind) -> Int {
            lock.withLock { $0.counts[kind.rawValue] }
        }
    }

    private struct WatchdogValues: Sendable {
        var started = false
        var acknowledgedSequence: UInt64 = 0
        var lastCheckpoint = "none"
    }

    private final class SharedState: Sendable {
        let lock = OSAllocatedUnfairLock<WatchdogValues>(initialState: WatchdogValues())

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

        while true {
            let now = clock.now
            if let priorPing = outstanding {
                let acknowledged = state.lock.withLock { $0.acknowledgedSequence >= priorPing.sequence }
                if acknowledged {
                    if let stallStartedAt = stalledSince {
                        logger.notice("main actor recovered after \(seconds(stallStartedAt.duration(to: now)), format: .fixed(precision: 1))s")
                        stalledSince = nil
                        lastStallLogAt = nil
                    }
                    outstanding = nil
                } else if let duration = stallDuration(now: now, pingSentAt: priorPing.sentAt, acked: false), duration >= .seconds(2) {
                    if stalledSince == nil { stalledSince = priorPing.sentAt }
                    if lastStallLogAt.map({ $0.duration(to: now) >= .seconds(5) }) ?? true {
                        let checkpoint = state.lock.withLock(\.lastCheckpoint)
                        logger.error(
                            "main actor unresponsive for \(seconds(duration), format: .fixed(precision: 1))s lastCheckpoint=\(checkpoint, privacy: .public) terminalBacklog=\(streamBacklog.current(.terminal)) piBacklog=\(streamBacklog.current(.pi)) footprintMB=\(currentFootprintMB())"
                        )
                        lastStallLogAt = now
                    }
                }
            }

            if lastFootprintAt.duration(to: now) >= .seconds(30) {
                let checkpoint = state.lock.withLock(\.lastCheckpoint)
                logger.info(
                    "footprint=\(currentFootprintMB())MB terminalBacklog=\(streamBacklog.current(.terminal)) piBacklog=\(streamBacklog.current(.pi)) checkpoint=\(checkpoint, privacy: .public)"
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
}
