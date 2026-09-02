import SwiftUI

struct SidebarReviewRequestsView: View {
    let items: [GitHubReviewRequest]
    let hiddenCount: Int
    let error: String?
    let isLoading: Bool
    let showAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error {
                Label {
                    Text(error)
                        .lineLimit(2)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(HerdrTheme.warning)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
            }

            if !items.isEmpty {
                // Plain VStack, not the Mac's ScrollView + LazyVStack: the
                // caller caps this list, and a nested vertical scroll would
                // fight the drawer's own scroll and its swipe-to-dismiss.
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(items) { request in
                        SidebarReviewRequestRow(request: request)
                    }
                }

                if hiddenCount > 0 {
                    Button(action: showAll) {
                        Text("show \(hiddenCount) more")
                            .font(.caption.bold())
                            .foregroundStyle(HerdrTheme.accent)
                            .padding(.horizontal, 9)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sidebar-my-work-github-show-all")
                    .accessibilityLabel("Show \(hiddenCount) more review requests")
                }
            } else if error == nil {
                Label(
                    isLoading ? "checking GitHub…" : "no review requests",
                    systemImage: isLoading ? "arrow.clockwise" : "checkmark.circle"
                )
                .font(.caption)
                .foregroundStyle(isLoading ? HerdrTheme.mist : HerdrTheme.success)
                .padding(.horizontal, 9)
                .frame(minHeight: 44)
            }
        }
    }
}
