import Foundation
import SwiftUI

struct CleanupTimelineView: View {
    let run: CleanupRun
    let failureMessage: String?
    let consecutivePollFailures: Int
    let lastPollFailureMessage: String?
    let lastPollSucceededAt: Date?
    let maxConsecutivePollFailures: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(timelinePhases, id: \.self) { phase in
                timelineRow(phase)
            }
            pollStatus
        }
    }

    private var timelinePhases: [CleanupPhase] {
        if run.status == .failed, run.phase == .failed || run.phase == nil {
            return [.failed]
        }
        var phases: [CleanupPhase] = [.collecting, .judging, .gating]
        if run.status == .applying || run.phase == .applying || run.phaseHistory.contains(where: { $0.phase == .applying }) {
            phases.append(.applying)
        }
        phases.append(.done)
        return phases
    }

    @ViewBuilder
    private func timelineRow(_ phase: CleanupPhase) -> some View {
        let entry = run.phaseHistory.first { $0.phase == phase }
        let active = activePhase == phase && !isComplete(entry)
        let failed = run.status == .failed && (run.phase == phase || phase == .failed)
        let complete = isComplete(entry) || (run.status == .done || run.status == .applied) && phase == .done
        let pending = !active && !complete && !failed

        HStack(alignment: .top, spacing: 12) {
            Image(systemName: failed ? "exclamationmark.triangle.fill" : complete ? "checkmark.circle.fill" : active ? "circle.inset.filled" : "circle")
                .foregroundStyle(failed ? HerdrTheme.alert : complete ? HerdrTheme.signal : active ? HerdrTheme.working : HerdrTheme.muted)
                .symbolEffect(.pulse, options: .repeating, isActive: active && !reduceMotion)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(phase.label)
                    .herdrFont(.subheadline, weight: .bold)
                    .foregroundStyle(pending ? HerdrTheme.muted : HerdrTheme.text)
                    .accessibilityLabel("\(phase.label), \(statusLabel(active: active, complete: complete, failed: failed))")
                Text(explanation(for: phase))
                    .herdrFont(.caption)
                    .foregroundStyle(pending ? HerdrTheme.muted : HerdrTheme.mist)
                if complete, let detail = entry?.detail {
                    Text("\(detail)\(durationText(for: entry).map { " · \($0)" } ?? "")")
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.mist)
                }
                if active {
                    if let progress = run.progress {
                        ProgressView(value: progress.fraction)
                            .tint(HerdrTheme.working)
                            .accessibilityLabel("\(phase.label) progress")
                            .accessibilityValue("\(progress.done) of \(progress.total)")
                    }
                    Text(run.phaseDetail ?? "Working…")
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.mist)
                    if let entry {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            if let elapsed = elapsedText(for: entry, at: context.date) {
                                Text("\(elapsed) elapsed")
                                    .herdrFont(.caption)
                                    .foregroundStyle(HerdrTheme.mist)
                            }
                        }
                    }
                }
                if failed, let failureMessage {
                    Text(failureMessage)
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.alert)
                        .textSelection(.enabled)
                }
            }
            .padding(.bottom, phase == .done ? 0 : 12)
        }
        .background(alignment: .topLeading) {
            if phase != .done {
                Rectangle()
                    .fill(pending ? HerdrTheme.surface : HerdrTheme.mist.opacity(0.4))
                    .frame(width: 1)
                    .padding(.leading, 9.5)
                    .padding(.top, 20)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private func isComplete(_ entry: CleanupPhaseHistoryEntry?) -> Bool {
        entry?.finishedAt != nil
    }

    private var activePhase: CleanupPhase? {
        if let phase = run.phase {
            return phase
        }
        switch run.status {
        case .collecting: return .collecting
        case .judging: return .judging
        case .gating: return .gating
        case .applying: return .applying
        case .done, .applied: return .done
        case .failed: return .failed
        case .partial, .unknown: return nil
        }
    }

    private func durationText(for entry: CleanupPhaseHistoryEntry?) -> String? {
        guard let startedAt = entry?.startedAt,
              let finishedAt = entry?.finishedAt,
              let start = Self.formatter.date(from: startedAt),
              let finish = Self.formatter.date(from: finishedAt) else { return nil }
        let seconds = max(0, Int(finish.timeIntervalSince(start).rounded()))
        return Self.durationText(seconds: seconds)
    }

    private func elapsedText(for entry: CleanupPhaseHistoryEntry, at date: Date) -> String? {
        guard let startedAt = entry.startedAt,
              let start = Self.formatter.date(from: startedAt) else { return nil }
        let seconds = max(0, Int(date.timeIntervalSince(start).rounded()))
        return Self.durationText(seconds: seconds)
    }

    private func explanation(for phase: CleanupPhase) -> String {
        switch phase {
        case .collecting:
            "Reads titles, recent output, alerts, activity, session identity, and known cost."
        case .judging:
            "A read-only AI summarizes how each pane was used and recommends keep or close."
        case .gating:
            "Deterministic checks protect work that is active, focused, starred, changed, unread, or unsafe in Git."
        case .applying:
            "Revalidates each selection, ends active Pi sessions, records associations, then closes approved items."
        case .done:
            "Shows the evidence and leaves every close decision to you."
        case .failed:
            "Stops safely without closing panes."
        }
    }

    private func statusLabel(active: Bool, complete: Bool, failed: Bool) -> String {
        if failed { return "failed" }
        if complete { return "complete" }
        if active { return "in progress" }
        return "pending"
    }

    @ViewBuilder
    private var pollStatus: some View {
        if failureMessage == nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 3) {
                    if consecutivePollFailures > 0 {
                        Text("connection hiccup · retrying (\(consecutivePollFailures) of \(maxConsecutivePollFailures))")
                            .herdrFont(.caption)
                            .foregroundStyle(HerdrTheme.alert)
                        if let lastPollFailureMessage {
                            Text(lastPollFailureMessage)
                                .herdrFont(.caption)
                                .foregroundStyle(HerdrTheme.alert)
                                .lineLimit(2)
                        }
                    } else if let lastPollSucceededAt {
                        Text("live · updated \(Self.durationText(seconds: max(0, Int(context.date.timeIntervalSince(lastPollSucceededAt).rounded())))) ago")
                            .herdrFont(.caption)
                            .foregroundStyle(HerdrTheme.mist)
                    } else {
                        Text("live")
                            .herdrFont(.caption)
                            .foregroundStyle(HerdrTheme.mist)
                    }
                }
                .padding(.top, 4)
                .accessibilityIdentifier("cleanup-poll-status")
            }
        }
    }

    private static func durationText(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    private static let formatter = ISO8601DateFormatter()
}
