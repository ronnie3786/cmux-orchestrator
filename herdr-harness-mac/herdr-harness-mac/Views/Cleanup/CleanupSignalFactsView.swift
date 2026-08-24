import SwiftUI

struct CleanupSignalFactsView: View {
    let pane: CleanupPaneReport

    var body: some View {
        CleanupFlowLayout(spacing: 6) {
            ForEach(facts.enumerated(), id: \.offset) { _, fact in
                Label(fact.label, systemImage: fact.symbol)
                    .herdrFont(.caption)
                    .foregroundStyle(fact.tone)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(fact.tone.opacity(0.11))
                    .clipShape(.capsule)
            }
        }
    }

    private var facts: [(label: String, symbol: String, tone: Color)] {
        guard let signals = pane.signals else { return [] }
        var result: [(String, String, Color)] = []
        if let status = signals.agentStatus {
            result.append(("Agent \(status.compactTitle.lowercased())", status == .working ? "waveform.path.ecg" : "circle.fill", status == .working ? HerdrTheme.working : HerdrTheme.mist))
        }
        if signals.revisionChanged == true {
            result.append(("Output changed during check", "waveform.path", HerdrTheme.working))
        } else if signals.revisionChanged == false {
            result.append(("Output unchanged during check", "waveform.path.badge.minus", HerdrTheme.signal))
        }
        if let age = signals.doneAlertAgeSeconds {
            result.append(("Done alert \(ageLabel(age)) ago", "checkmark.bubble", HerdrTheme.mist))
        }
        if let age = signals.piStateAgeSeconds {
            result.append(("Pi activity \(ageLabel(age)) ago", "clock", HerdrTheme.mist))
        } else if let age = signals.sessionFileAgeSeconds {
            result.append(("Session updated \(ageLabel(age)) ago", "clock", HerdrTheme.mist))
        }
        if pane.piSession?.detected == true {
            if signals.piActive == true {
                result.append(("Pi session active", "bolt.horizontal.circle.fill", HerdrTheme.working))
            } else if signals.piConnected == false || signals.piActive == false {
                result.append(("Pi session inactive", "moon.zzz.fill", HerdrTheme.mist))
            }
        }
        if let alerts = signals.unreadAlerts {
            result.append((alerts == 0 ? "No unread alerts" : "\(alerts) unread alerts", alerts == 0 ? "bell.slash" : "bell.badge.fill", alerts == 0 ? HerdrTheme.signal : HerdrTheme.alert))
        }
        if signals.endsAtShellPrompt == true {
            result.append(("At shell prompt", "terminal", HerdrTheme.mist))
        }
        if signals.tailIsEmpty == true {
            result.append(("No recent terminal output", "text.page.slash", HerdrTheme.mist))
        }
        if signals.tailTruncated == true {
            result.append(("Evidence truncated", "ellipsis.rectangle", HerdrTheme.working))
        }
        if signals.starred == true {
            result.append(("Starred", "star.fill", HerdrTheme.working))
        }
        if signals.focused == true {
            result.append(("Focused", "scope", HerdrTheme.working))
        }
        return result
    }

    private func ageLabel(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        if value < 60 { return "<1m" }
        if value < 3_600 { return "\(value / 60)m" }
        if value < 86_400 { return "\(value / 3_600)h" }
        return "\(value / 86_400)d"
    }
}
