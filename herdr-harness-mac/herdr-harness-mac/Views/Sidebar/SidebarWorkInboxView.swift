import SwiftUI

struct SidebarWorkInboxView: View {
    @Bindable var store: WorkInboxStore
    let refreshID: Int
    let refresh: @MainActor () async -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expandedProvider: WorkInboxProvider? = .github

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("my work")
                    .bold()
                    .underline()
                    .herdrFont(.subheadline)
                    .foregroundStyle(HerdrTheme.mist)

                Spacer(minLength: 4)

                Text(store.hasLoaded ? "\(store.totalCount) watching" : "checking")
                    .herdrFont(.caption, monospacedDigit: true)
                    .foregroundStyle(HerdrTheme.mist)

                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing my work")
                } else if store.hasError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(HerdrTheme.warning)
                        .accessibilityLabel("Some work items could not be refreshed")
                }

                Button("Refresh my work", systemImage: "arrow.clockwise", action: refreshNow)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(HerdrTheme.mist)
                    .disabled(store.isRefreshing)
                    .help("Refresh GitHub review requests and Jira tickets")
            }
            .padding(.horizontal, 9)
            .padding(.bottom, 4)

            SidebarWorkProviderHeader(
                provider: .github,
                count: store.response.reviewRequests.items.count,
                isExpanded: expandedProvider == .github,
                hasError: store.error(for: .github) != nil,
                action: { toggle(.github) }
            )

            if expandedProvider == .github {
                SidebarReviewRequestsView(
                    items: store.response.reviewRequests.items,
                    error: store.error(for: .github),
                    isLoading: !store.hasLoaded || store.isRefreshing
                )
            }

            SidebarWorkProviderHeader(
                provider: .jira,
                count: store.response.jiraTickets.items.count,
                isExpanded: expandedProvider == .jira,
                hasError: store.error(for: .jira) != nil,
                action: { toggle(.jira) }
            )

            if expandedProvider == .jira {
                SidebarJiraTicketsView(
                    items: store.response.jiraTickets.items,
                    error: store.error(for: .jira),
                    isLoading: !store.hasLoaded || store.isRefreshing
                )
            }
        }
        .padding(.vertical, 8)
        .background(HerdrTheme.graphite, in: .rect(cornerRadius: HerdrTheme.compactRadius))
        .overlay(alignment: .leading) {
            VStack(spacing: 0) {
                Rectangle().fill(HerdrTheme.mauve)
                Rectangle().fill(HerdrTheme.accent)
            }
            .frame(width: 3)
            .clipShape(.rect(cornerRadius: 2))
            .accessibilityHidden(true)
        }
        .accessibilityIdentifier("sidebar-my-work")
        .task(id: refreshID) {
            await pollWorkInbox()
        }
    }

    private func refreshNow() {
        Task { await refresh() }
    }

    private func toggle(_ provider: WorkInboxProvider) {
        withAnimation(reduceMotion ? nil : .snappy) {
            expandedProvider = expandedProvider == provider ? nil : provider
        }
    }

    private func pollWorkInbox() async {
        await refresh()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(300))
            } catch {
                return
            }
            await refresh()
        }
    }
}
