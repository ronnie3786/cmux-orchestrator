import SwiftUI

/// The history behind the Attention tab: done and blocked transitions across
/// every machine, including signals already cleared.
///
/// The Mac centers this in an 820 pt column and puts an inline refresh button
/// in the header. A phone is already narrower than that column, and pull-to-
/// refresh is the touch idiom, so the button moves to the toolbar — where it
/// also stays reachable for Switch Control and VoiceOver, which have no
/// pull gesture.
struct ActivityFeedView: View {
    @Bindable var model: HerdrAppModel
    let selectPane: (HerdrPane) -> Void

    @State private var filter = ActivityFeedFilter.all
    @State private var machineID = ""

    var body: some View {
        ZStack {
            HerdrBackground()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    header
                    ActivityFilterBar(filter: $filter)
                    machineFilter
                    errorBanner
                    if model.isRefreshingActivity && model.activityFeedAlerts.isEmpty {
                        loadingState
                    } else if days.isEmpty {
                        emptyState
                    } else {
                        ForEach(days) { day in
                            daySection(day)
                        }
                    }
                }
                .padding(.horizontal, HerdrTheme.pagePadding)
                .padding(.vertical, 22)
            }
            .scrollIndicators(.hidden)
            .refreshable { await model.refreshActivityFeed() }
        }
        .navigationTitle("Activity")
        // The ported header already carries a largeTitle "Activity feed"; two
        // large titles stacked reads as a bug.
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refreshActivityFeed() }
                }
                .disabled(model.isRefreshingActivity)
                .accessibilityIdentifier("activity-refresh")
            }
        }
        .task { await model.refreshActivityFeed() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Activity feed", systemImage: "clock.arrow.circlepath")
                .font(.largeTitle.bold())
                .fontDesign(.rounded)
            Text("Done and blocked transitions across your machines, including signals you have already cleared.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var machineFilter: some View {
        HStack(spacing: 10) {
            if model.machines.count > 1 {
                // A menu picker is already touch-native, so this one stays a
                // Picker where the status filter above became buttons.
                Picker("Machine", selection: $machineID) {
                    Text("All machines").tag("")
                    ForEach(model.machines) { machine in
                        Text(machine.name).tag(machine.id)
                    }
                }
                .pickerStyle(.menu)
                .tint(HerdrTheme.accent)
                .frame(minHeight: 44)
                .accessibilityIdentifier("activity-machine-filter")
            }
            Spacer(minLength: 8)
            Text("\(visibleCount) signals")
                .font(.caption.monospaced())
                .foregroundStyle(HerdrTheme.muted)
        }
    }

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView().tint(HerdrTheme.accent)
            Text("Loading activity from every machine…")
                .font(.body)
                .foregroundStyle(HerdrTheme.mist)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 46)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = model.activityFeedError, !message.isEmpty {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Some machines could not refresh")
                        .font(.subheadline.bold())
                    Text(message)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(HerdrTheme.alert)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HerdrTheme.alert.opacity(0.1))
            .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
            .accessibilityIdentifier("activity-refresh-error")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No matching activity",
            systemImage: "clock.badge.checkmark",
            description: Text("Done and blocked agent transitions will collect here.")
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 38)
    }

    private var days: [ActivityFeedDay] {
        ActivityFeed.days(
            alerts: model.activityFeedAlerts,
            filter: filter,
            machineID: machineID.isEmpty ? nil : machineID
        )
    }

    private var visibleCount: Int {
        days.reduce(0) { $0 + $1.alerts.count }
    }

    private func daySection(_ day: ActivityFeedDay) -> some View {
        Section {
            ForEach(day.alerts) { alert in
                let pane = model.pane(id: alert.scopedPaneID)
                ActivityFeedRow(
                    alert: alert,
                    pane: pane,
                    machineName: machineName(for: alert.machineID),
                    action: pane.map { pane in { selectPane(pane) } }
                )
            }
        } header: {
            Text(dayTitle(day.date))
                .font(.caption.monospaced().bold())
                .foregroundStyle(HerdrTheme.mist)
                .padding(.top, 6)
        }
    }

    private func machineName(for id: String) -> String {
        model.machines.first(where: { $0.id == id })?.name ?? "unknown machine"
    }

    private func dayTitle(_ date: Date) -> String {
        if date == .distantPast { return "UNKNOWN DATE" }
        if Calendar.autoupdatingCurrent.isDateInToday(date) { return "TODAY" }
        if Calendar.autoupdatingCurrent.isDateInYesterday(date) { return "YESTERDAY" }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()).uppercased()
    }
}

/// The Mac uses a segmented `Picker`; on iOS this matches `WorkspaceFilterBar`
/// so the filter reads as one of ours and keeps a 44 pt target at every
/// Dynamic Type size.
private struct ActivityFilterBar: View {
    @Binding var filter: ActivityFeedFilter

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ActivityFeedFilter.allCases) { item in
                Button {
                    withAnimation(.snappy) { filter = item }
                } label: {
                    Text(item.title.lowercased())
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .font(.subheadline.monospaced().bold())
                .foregroundStyle(filter == item ? HerdrTheme.ink : HerdrTheme.mist)
                .background(filter == item ? HerdrTheme.accent : HerdrTheme.graphite)
                .overlay {
                    Rectangle().strokeBorder(HerdrTheme.surface.opacity(0.8), lineWidth: 1)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(filter == item ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Activity filter")
        .accessibilityIdentifier("activity-filter")
    }
}
