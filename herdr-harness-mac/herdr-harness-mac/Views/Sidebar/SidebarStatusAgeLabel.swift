import SwiftUI

struct SidebarStatusAgeLabel: View {
    let status: AgentStatus
    let since: Date?

    var body: some View {
        if let since {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text("\(status.title.lowercased()) · \(HerdrTimestamp.compactAge(since: since, now: context.date))")
                    .accessibilityLabel("\(status.title), \(HerdrTimestamp.spokenAge(since: since, now: context.date))")
            }
        } else {
            Text(status.title.lowercased())
                .accessibilityLabel(status.title)
        }
    }
}
