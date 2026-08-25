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

    private var content: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: alert.status.symbol)
                .herdrFont(.headline)
                .foregroundStyle(alert.status.color)
                .frame(width: 32, height: 32)
                .background(alert.status.color.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(alert.title)
                        .herdrFont(.headline, weight: .bold)
                        .foregroundStyle(HerdrTheme.text)
                        .lineLimit(1)
                    if !alert.isRead {
                        Text("NEW")
                            .herdrFont(.caption, monospaced: true, weight: .bold)
                            .foregroundStyle(HerdrTheme.ink)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(HerdrTheme.accent, in: Capsule())
                    }
                }

                if !alert.message.isEmpty {
                    Text(alert.message)
                        .herdrFont(.subheadline)
                        .foregroundStyle(HerdrTheme.mist)
                        .lineLimit(2)
                }

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
                    .herdrFont(.caption, monospaced: true)
                    .foregroundStyle(HerdrTheme.muted)
                    .lineLimit(1)
                }
            }

            Spacer(minLength: 8)
            if action != nil {
                Image(systemName: "chevron.right")
                    .herdrFont(.caption, weight: .bold)
                    .foregroundStyle(HerdrTheme.muted)
                    .padding(.top, 5)
                    .accessibilityHidden(true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HerdrTheme.graphite)
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(HerdrTheme.surface, lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
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
