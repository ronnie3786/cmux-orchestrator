import SwiftUI

struct SidebarStatusAgeLabel: View {
    let status: AgentStatus
    let since: Date?
    /// Recents ranks by last activity, so its rows age that instead of the
    /// status. Only the spoken label says so — the compact text is the same
    /// either way, and the number is what explains the row's position.
    var describesLastActivity = false

    var body: some View {
        if let since {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text("\(status.title.lowercased()) · \(HerdrTimestamp.compactAge(since: since, now: context.date))")
                    .accessibilityLabel(spokenLabel(now: context.date))
            }
        } else {
            Text(status.title.lowercased())
                .accessibilityLabel(status.title)
        }
    }

    private func spokenLabel(now: Date) -> String {
        guard let since else { return status.title }
        let age = HerdrTimestamp.spokenAge(since: since, now: now)
        return describesLastActivity
            ? "\(status.title), last active \(age)"
            : "\(status.title), \(age)"
    }
}
