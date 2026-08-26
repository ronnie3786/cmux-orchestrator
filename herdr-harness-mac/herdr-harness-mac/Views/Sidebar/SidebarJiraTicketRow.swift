import SwiftUI

struct SidebarJiraTicketRow: View {
    let ticket: JiraTicket
    @Environment(\.openURL) private var openURL
    @State private var isHovering = false

    var body: some View {
        Button(action: openTicket) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(ticket.key)
                        .herdrFont(.caption, monospaced: true, weight: .bold)
                        .foregroundStyle(HerdrTheme.accent)

                    Spacer(minLength: 4)

                    Label(ticket.status, systemImage: ticket.workInboxStatus.symbolName)
                        .herdrFont(.caption, monospaced: true, weight: .bold)
                        .foregroundStyle(statusTone)
                        .lineLimit(1)
                }

                Text(ticket.title)
                    .herdrFont(.subheadline)
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
                .herdrFont(.caption, monospaced: true)
                .foregroundStyle(HerdrTheme.muted)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 9)
            .background(isHovering ? HerdrTheme.elevated.opacity(0.68) : .clear)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(HerdrTheme.accent)
                    .frame(width: 2)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(ticket.workInboxURL == nil)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier("sidebar-jira-ticket-\(ticket.key)")
        .help("Open \(ticket.key) in Jira")
        .accessibilityLabel(
            "Jira ticket \(ticket.key), \(ticket.title), status \(ticket.status)"
        )
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
