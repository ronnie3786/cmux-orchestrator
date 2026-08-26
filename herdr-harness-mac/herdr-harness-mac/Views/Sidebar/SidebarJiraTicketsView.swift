import SwiftUI

struct SidebarJiraTicketsView: View {
    let items: [JiraTicket]
    let error: String?
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error {
                Label {
                    Text(error)
                        .lineLimit(2)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.warning)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
            }

            if !items.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(items) { ticket in
                            SidebarJiraTicketRow(ticket: ticket)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: 190)
            } else if error == nil {
                Label(
                    isLoading ? "checking Jira…" : "no assigned active tickets",
                    systemImage: isLoading ? "arrow.clockwise" : "checkmark.circle"
                )
                .herdrFont(.caption, monospaced: true)
                .foregroundStyle(isLoading ? HerdrTheme.mist : HerdrTheme.success)
                .padding(.horizontal, 9)
                .frame(minHeight: 34)
            }
        }
    }
}
