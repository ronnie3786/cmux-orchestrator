import Foundation
import SwiftUI

struct CleanupTimelineView: View {
    let run: CleanupRun
    let failureMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(timelinePhases, id: \.self) { phase in
                timelineRow(phase)
            }
        }
    }

    private var timelinePhases: [CleanupPhase] { [.collecting, .judging, .gating, .done] }

    @ViewBuilder
    private func timelineRow(_ phase: CleanupPhase) -> some View {
        let entry = run.phaseHistory.first { $0.phase == phase }
        let active = run.phase == phase && !isComplete(entry)
        let failed = run.status == .failed && (run.phase == phase || phase == .failed)
        let complete = isComplete(entry) || run.status == .done && phase == .done
        let pending = !active && !complete && !failed

        HStack(alignment: .top, spacing: 12) {
            Image(systemName: failed ? "exclamationmark.triangle.fill" : complete ? "checkmark.circle.fill" : active ? "circle.inset.filled" : "circle")
                .foregroundStyle(failed ? HerdrTheme.alert : complete ? HerdrTheme.signal : active ? HerdrTheme.working : HerdrTheme.muted)
                .symbolEffect(.pulse, options: .repeating, isActive: active)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 5) {
                Text(phase.label)
                    .herdrFont(.subheadline, weight: .bold)
                    .foregroundStyle(pending ? HerdrTheme.muted : HerdrTheme.text)
                if complete, let detail = entry?.detail {
                    Text("\(detail)\(durationText(for: entry).map { " · \($0)" } ?? "")")
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.mist)
                }
                if active {
                    if let progress = run.progress {
                        ProgressView(value: progress.fraction)
                            .tint(HerdrTheme.working)
                    }
                    Text(run.phaseDetail ?? "Working…")
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.mist)
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

    private func durationText(for entry: CleanupPhaseHistoryEntry?) -> String? {
        guard let startedAt = entry?.startedAt,
              let finishedAt = entry?.finishedAt,
              let start = Self.formatter.date(from: startedAt),
              let finish = Self.formatter.date(from: finishedAt) else { return nil }
        let seconds = max(0, Int(finish.timeIntervalSince(start).rounded()))
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    private static let formatter = ISO8601DateFormatter()
}
