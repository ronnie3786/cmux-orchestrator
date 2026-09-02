import SwiftUI

/// The work inbox in the navigator drawer.
///
/// The Mac renders this as an always-visible card in a persistent column. The
/// drawer has one scroll region and far less vertical room, so iOS adds an
/// outer disclosure: the "my work" header is itself the toggle, the section
/// stays collapsed until the reader opts in, and that opt-in is what arms the
/// fetch. Until then the inbox costs one row and zero network.
struct SidebarWorkInboxView: View {
    @Bindable var model: HerdrAppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expandedProvider: WorkInboxProvider? = .github
    @State private var showsAllItems: Set<WorkInboxProvider> = []

    /// The drawer is torn down on dismiss, so this view's `.task` runs again on
    /// every open. Two minutes keeps the counts honest without putting a round
    /// trip behind every tap of the navigator button.
    private static let freshnessWindow: TimeInterval = 120

    /// The Mac clamps each provider list to 190pt and scrolls inside it. A
    /// nested vertical ScrollView here would fight both the drawer's outer
    /// scroll and its edge-swipe-to-dismiss drag, so the rows render inline and
    /// the count is capped instead — same intent, touch-native mechanism.
    private static let itemLimit = 6

    private var store: WorkInboxStore { model.workInbox }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            inboxHeader

            if model.isWorkInboxExpanded {
                SidebarWorkProviderHeader(
                    provider: .github,
                    count: store.response.reviewRequests.items.count,
                    isExpanded: expandedProvider == .github,
                    hasError: store.error(for: .github) != nil,
                    action: { toggle(.github) }
                )

                if expandedProvider == .github {
                    SidebarReviewRequestsView(
                        items: visibleItems(store.response.reviewRequests.items, for: .github),
                        hiddenCount: hiddenCount(store.response.reviewRequests.items, for: .github),
                        error: store.error(for: .github),
                        isLoading: !store.hasLoaded || store.isRefreshing,
                        showAll: { showAll(.github) }
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
                        items: visibleItems(store.response.jiraTickets.items, for: .jira),
                        hiddenCount: hiddenCount(store.response.jiraTickets.items, for: .jira),
                        error: store.error(for: .jira),
                        isLoading: !store.hasLoaded || store.isRefreshing,
                        showAll: { showAll(.jira) }
                    )
                }
            }
        }
        .padding(.vertical, 8)
        .background(HerdrTheme.graphite, in: RoundedRectangle(cornerRadius: HerdrTheme.compactRadius))
        .overlay(alignment: .leading) {
            VStack(spacing: 0) {
                Rectangle().fill(HerdrTheme.mauve)
                Rectangle().fill(HerdrTheme.accent)
            }
            .frame(width: 3)
            .clipShape(.rect(cornerRadius: 2))
            .accessibilityHidden(true)
        }
        // The card keeps the Mac's identifier, but it has to be a *container*
        // element first: an identifier on a plain UIKit-backed stack propagates
        // down and overwrites every identifier inside it, which cost the
        // header, both provider rows and every work item their own names.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar-my-work")
        .task(id: "work-inbox:\(model.connectionGeneration):\(model.isWorkInboxExpanded)") {
            // Nothing is fetched until the reader has opened the inbox at least
            // once; the flag is persisted, so after that the badge stays warm.
            guard model.isWorkInboxExpanded else { return }
            guard store.isStale(olderThan: Self.freshnessWindow) else { return }
            await model.refreshWorkInbox()
        }
    }

    private var inboxHeader: some View {
        HStack(spacing: 0) {
            Button(action: toggleInbox) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.bold())
                        .rotationEffect(.degrees(model.isWorkInboxExpanded ? 90 : 0))
                        .animation(.snappy, value: model.isWorkInboxExpanded)
                        .foregroundStyle(HerdrTheme.mist)
                        .accessibilityHidden(true)

                    Text("my work")
                        .font(.subheadline.bold())
                        .underline()
                        .foregroundStyle(HerdrTheme.mist)

                    Spacer(minLength: 4)

                    Text(headerDetail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(HerdrTheme.mist)

                    if store.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .tint(HerdrTheme.mist)
                            .accessibilityHidden(true)
                    } else if store.hasError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(HerdrTheme.warning)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.leading, 9)
                .padding(.trailing, model.isWorkInboxExpanded ? 0 : 9)
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar-my-work-toggle")
            .accessibilityLabel("My work, \(accessibilityDetail)")
            .accessibilityValue(model.isWorkInboxExpanded ? "expanded" : "collapsed")
            .accessibilityHint("Shows or hides assigned Jira tickets and GitHub review requests")

            if model.isWorkInboxExpanded {
                Button(action: refreshNow) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(HerdrTheme.mist)
                .disabled(store.isRefreshing)
                .accessibilityIdentifier("sidebar-my-work-refresh")
                .accessibilityLabel("Refresh my work")
            }
        }
    }

    private var headerDetail: String {
        if !model.isWorkInboxExpanded && !store.hasLoaded { return "tap to load" }
        return store.hasLoaded ? "\(store.totalCount) watching" : "checking"
    }

    private var accessibilityDetail: String {
        if !model.isWorkInboxExpanded && !store.hasLoaded { return "not loaded yet" }
        return store.hasLoaded ? "\(store.totalCount) items" : "checking"
    }

    private func refreshNow() {
        Task { await model.refreshWorkInbox() }
    }

    private func toggleInbox() {
        withAnimation(reduceMotion ? nil : .snappy) {
            model.setWorkInboxExpanded(!model.isWorkInboxExpanded)
        }
    }

    private func toggle(_ provider: WorkInboxProvider) {
        withAnimation(reduceMotion ? nil : .snappy) {
            expandedProvider = expandedProvider == provider ? nil : provider
            // Collapsing a provider forgets that it was fully expanded, so the
            // list never reopens taller than the cap.
            showsAllItems.remove(provider)
        }
    }

    private func showAll(_ provider: WorkInboxProvider) {
        withAnimation(reduceMotion ? nil : .snappy) {
            _ = showsAllItems.insert(provider)
        }
    }

    private func visibleItems<Item>(_ items: [Item], for provider: WorkInboxProvider) -> [Item] {
        showsAllItems.contains(provider) ? items : Array(items.prefix(Self.itemLimit))
    }

    private func hiddenCount<Item>(_ items: [Item], for provider: WorkInboxProvider) -> Int {
        showsAllItems.contains(provider) ? 0 : max(0, items.count - Self.itemLimit)
    }
}
