import SwiftUI

struct SidebarJiraTicketRow: View {
    let ticket: JiraTicket
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button(action: openTicket) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(ticket.key)
                        .font(.caption.monospaced().bold())
                        .foregroundStyle(HerdrTheme.accent)

                    Spacer(minLength: 4)

                    Label(ticket.status, systemImage: ticket.workInboxStatus.symbolName)
                        .font(.caption.bold())
                        .foregroundStyle(statusTone)
                        .lineLimit(1)
                }

                Text(ticket.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 6) {
                    Text(ticket.issueType.lowercased())
                    if !ticket.priority.isEmpty {
                        Text("·")
                            .accessibilityHidden(true)
                        Text(ticket.priority.lowercased())
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.up.right")
                        .accessibilityHidden(true)
                }
                .font(.caption)
                .foregroundStyle(HerdrTheme.muted)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(HerdrTheme.accent)
                    .frame(width: 2)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(ticket.workInboxURL == nil)
        .accessibilityIdentifier("sidebar-jira-ticket-\(ticket.key)")
        .accessibilityLabel(
            "Jira ticket \(ticket.key), \(ticket.title), status \(ticket.status)"
        )
        // The Mac says this in a `.help` tooltip. There is no pointer here, so
        // the hint is the only place the destination can be stated.
        .accessibilityHint("Opens the ticket in your browser")
    }

    private var statusTone: Color {
        switch ticket.workInboxStatus {
        case .inProgress: HerdrTheme.working
        case .codeReview: HerdrTheme.mauve
        case .blocked: HerdrTheme.alert
        case .queued: HerdrTheme.mist
        case .other: HerdrTheme.accent
        }
    }

    private func openTicket() {
        guard let url = ticket.workInboxURL else { return }
        openURL(url)
    }
}
