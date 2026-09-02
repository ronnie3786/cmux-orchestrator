import SwiftUI

struct ActivityFeedRow: View {
    let alert: HerdrAlert
    let pane: HerdrPane?
    let machineName: String
    let action: (() -> Void)?

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    content
                }
                .buttonStyle(.plain)
            } else {
                content
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(action == nil ? "This pane is closed" : "Opens this chat")
        .accessibilityIdentifier("activity-alert-\(alert.id)")
    }

    // A 32 pt glyph inside 14 pt padding puts the tappable card well past the
    // 44 pt minimum even for a single-line alert, so no explicit minHeight.
    private var content: some View {
        GlassCard(radius: HerdrTheme.compactRadius) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: alert.status.symbol)
                    .font(.headline)
                    .foregroundStyle(alert.status.color)
                    .frame(width: 32, height: 32)
                    .background(alert.status.color.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(alert.title)
                            .font(.headline.bold())
                            .foregroundStyle(HerdrTheme.text)
                            .lineLimit(2)
                        if !alert.isRead {
                            Text("NEW")
                                .font(.caption.monospaced().bold())
                                .foregroundStyle(HerdrTheme.ink)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(HerdrTheme.accent, in: Capsule())
                        }
                    }

                    if !alert.message.isEmpty {
                        Text(alert.message)
                            .font(.subheadline)
                            .foregroundStyle(HerdrTheme.mist)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // One tick a minute is all "12m" needs, and it keeps a long
                    // feed from re-rendering every frame.
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        HStack(spacing: 6) {
                            Text(machineName.lowercased())
                            Text("·")
                            Text(pane?.displayAgentName.lowercased() ?? "closed pane")
                            if let createdDate = alert.createdDate {
                                Text("·")
                                Text(HerdrTimestamp.compactAge(since: createdDate, now: context.date))
                            }
                        }
                        .font(.caption.monospaced())
                        .foregroundStyle(HerdrTheme.muted)
                        .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(HerdrTheme.muted)
                        .padding(.top, 5)
                        .accessibilityHidden(true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var accessibilityLabel: String {
        var parts = [alert.title, alert.status.title, alert.message, machineName]
        if let pane {
            parts.append(pane.displayAgentName)
        } else {
            parts.append("Closed pane")
        }
        if let createdDate = alert.createdDate {
            parts.append(HerdrTimestamp.spokenAge(since: createdDate, now: .now))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
