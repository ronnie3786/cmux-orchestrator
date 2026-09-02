import SwiftUI

/// The status word and how long it has held it, e.g. `working · 47m`.
///
/// `TimelineView(.periodic(by: 60))` re-renders only this label once a minute
/// instead of invalidating the whole row every time the clock moves. The
/// navigator is a drawer — `SidebarDrawer` only builds `HerdrSidebarView` while
/// `model.isSidebarPresented` is true — so every timeline in the column is torn
/// down when the drawer closes and nothing ticks behind it.
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
