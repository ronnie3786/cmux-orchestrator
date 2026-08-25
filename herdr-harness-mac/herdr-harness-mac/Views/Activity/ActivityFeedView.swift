import SwiftUI

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
                    filters
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
                .frame(maxWidth: 820, alignment: .leading)
                .padding(.horizontal, HerdrTheme.pagePadding)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Activity")
        .task { await model.refreshActivityFeed() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Activity feed", systemImage: "clock.arrow.circlepath")
                    .herdrFont(.largeTitle, weight: .bold)
                    .fontDesign(.rounded)
                Text("Done and blocked transitions across your machines, including signals you have already cleared.")
                    .herdrFont(.body)
                    .foregroundStyle(HerdrTheme.mist)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await model.refreshActivityFeed() }
            }
            .labelStyle(.iconOnly)
            .frame(width: 44, height: 44)
            .background(HerdrTheme.elevated)
            .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
            .buttonStyle(.plain)
            .disabled(model.isRefreshingActivity)
            .accessibilityIdentifier("activity-refresh")
        }
    }

    private var filters: some View {
        HStack(spacing: 10) {
            Picker("Signal", selection: $filter) {
                ForEach(ActivityFeedFilter.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            .accessibilityIdentifier("activity-filter")

            if model.machines.count > 1 {
                Picker("Machine", selection: $machineID) {
                    Text("All machines").tag("")
                    ForEach(model.machines) { machine in
                        Text(machine.name).tag(machine.id)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("activity-machine-filter")
            }
            Spacer()
            Text("\(visibleCount) signals")
                .herdrFont(.caption, monospaced: true)
                .foregroundStyle(HerdrTheme.muted)
        }
    }

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView().tint(HerdrTheme.accent)
            Text("Loading activity from every machine…")
                .herdrFont(.body)
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
                        .herdrFont(.subheadline, weight: .bold)
                    Text(message)
                        .herdrFont(.caption, monospaced: true)
                        .textSelection(.enabled)
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
                .herdrFont(.caption, monospaced: true, weight: .bold)
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
