import SwiftUI

/// Fleet on iPhone is READ-ONLY: it reports which machine carries which skill,
/// Pi extension, and CLI tool, and where they disagree. Sync, install, manage,
/// update, and remove all stay on the Mac harness — see `FleetStore`, which
/// has no action API to call.
///
/// The Mac renders this as a hover-driven machine constellation over a matrix
/// with one 190 pt column per machine. Neither survives phone width, so the
/// constellation becomes a vertical list of tap-to-expand machine cards and
/// the matrix is transposed: one card per item, with its per-machine states
/// stacked inside.
struct FleetInventoryView: View {
    @State private var store: FleetStore
    /// The Mac tracks `selectedMachineID` only to brighten a circuit trace on
    /// hover. Repurposed here as the inline-expansion target.
    @State private var expandedMachineID: String?

    init(model: HerdrAppModel) {
        _store = State(initialValue: FleetStore(model: model))
    }

    var body: some View {
        ZStack {
            HerdrBackground()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    summaryHeader
                    machineSection
                    inventorySection
                }
                .padding(.horizontal, HerdrTheme.pagePadding)
                .padding(.vertical, 20)
            }
            .scrollIndicators(.hidden)
            .refreshable { await store.refresh() }
        }
        .navigationTitle("Fleet")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await store.refresh() }
                }
                .disabled(store.isLoading)
                .accessibilityIdentifier("fleet-refresh-button")
            }
        }
        .task { await store.refresh() }
        .accessibilityIdentifier("fleet-inventory-view")
    }

    // MARK: Summary

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Fleet", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.largeTitle.bold())
                .fontDesign(.rounded)

            Text(fleetSummary)
                .font(.caption.monospaced())
                .foregroundStyle(HerdrTheme.mist)

            Text("Read-only on iPhone. Sync, install, and remove stay on the Mac.")
                .font(.caption)
                .foregroundStyle(HerdrTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            if store.driftCount > 0 {
                Label("\(store.driftCount) differences", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(HerdrTheme.mauve)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(HerdrTheme.mauve.opacity(0.11), in: Capsule())
            }
        }
    }

    // The Mac writes `lastRefreshAt` and never reads it. Here it earns its
    // keep: with no sync button to confirm an action, the age line is the only
    // signal that the screen is showing fresh data.
    private var fleetSummary: String {
        guard !store.machines.isEmpty else { return "No machines configured" }
        let online = "\(store.onlineCount) of \(store.machines.count) online"
        guard let lastRefreshAt = store.lastRefreshAt else { return online }
        // `compactAge` says "now" under a minute, which "… ago" turns into
        // "updated now ago".
        let age = HerdrTimestamp.compactAge(since: lastRefreshAt)
        return age == "now" ? "\(online) · updated just now" : "\(online) · updated \(age) ago"
    }

    // MARK: Machines

    private var machineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HerdrSectionLabel(
                title: "machines",
                detail: "\(store.onlineCount)/\(store.machines.count) online"
            )

            if store.machines.isEmpty {
                ContentUnavailableView(
                    "No machines configured",
                    systemImage: "server.rack",
                    description: Text("Add a machine in Settings to start your fleet.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ForEach(store.machines) { machine in
                    FleetMachineCard(
                        machine: machine,
                        isExpanded: expandedMachineID == machine.id,
                        error: store.machineErrors[machine.id],
                        toggle: {
                            withAnimation(.snappy) {
                                expandedMachineID = expandedMachineID == machine.id ? nil : machine.id
                            }
                        }
                    )
                }
            }
        }
        .accessibilityIdentifier("fleet-machine-list")
    }

    // MARK: Inventory

    private var inventorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HerdrSectionLabel(title: "inventory", detail: inventorySummary)

            FleetCategoryFilterBar(selection: $store.selectedFilter)

            Toggle("differences only", isOn: $store.differencesOnly)
                .font(.subheadline.monospaced().bold())
                .foregroundStyle(HerdrTheme.mist)
                .tint(HerdrTheme.accent)
                .frame(minHeight: 44)
                .accessibilityIdentifier("fleet-differences-toggle")

            WorkspaceSearchField(
                text: $store.searchText,
                placeholder: "search inventory",
                accessibilityLabel: "Search inventory",
                clearAccessibilityLabel: "Clear inventory search"
            )
            .accessibilityIdentifier("fleet-search-field")

            if store.isLoading && store.items.isEmpty {
                loadingCard
            } else if store.filteredItems.isEmpty {
                emptyCard
            } else {
                ForEach(store.filteredItems) { item in
                    FleetInventoryCard(store: store, item: item)
                }
            }
        }
    }

    private var inventorySummary: String {
        if store.totalItemCount == 0 { return "nothing reported yet" }
        let differenceText = store.differenceCount == 0
            ? "in sync"
            : "\(store.differenceCount) need attention"
        return "\(store.totalItemCount) items · \(differenceText)"
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView().tint(HerdrTheme.accent)
            Text("Reading inventory…")
                .font(.subheadline.monospaced())
                .foregroundStyle(HerdrTheme.mist)
        }
        .frame(maxWidth: .infinity, minHeight: 92)
        .background(HerdrTheme.graphite, in: .rect(cornerRadius: HerdrTheme.compactRadius))
    }

    private var emptyCard: some View {
        ContentUnavailableView(
            store.items.isEmpty ? "No inventory reported" : "No matching items",
            systemImage: "shippingbox",
            description: Text(
                store.items.isEmpty
                    ? "Refresh a connected machine to see its catalog."
                    : "Try a different filter or search."
            )
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

// MARK: - Machine card

/// The Mac shows this detail on hover, inside a floating overlay. Touch has no
/// hover, so the same content expands in place on tap.
private struct FleetMachineCard: View {
    let machine: FleetMachineSnapshot
    let isExpanded: Bool
    let error: String?
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            GlassCard(radius: HerdrTheme.compactRadius) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: machine.kind.symbol)
                            .font(.title2)
                            .foregroundStyle(HerdrTheme.accent)
                            .frame(width: 34)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(machine.displayName)
                                .font(.headline.bold())
                                .foregroundStyle(HerdrTheme.text)
                                .lineLimit(1)
                            Text(machine.kind.label)
                                .font(.caption.monospaced())
                                .foregroundStyle(HerdrTheme.accent)
                        }

                        Spacer(minLength: 8)

                        FleetStatusMark(isOnline: machine.online)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.bold())
                            .foregroundStyle(HerdrTheme.muted)
                            .accessibilityHidden(true)
                    }

                    HStack(spacing: 7) {
                        Text(machine.statusLabel)
                        Text("·")
                        Text(machine.countSummary)
                        if machine.driftCount > 0 {
                            Text("·")
                            Label("\(machine.driftCount) drift", systemImage: "arrow.triangle.2.circlepath")
                                .foregroundStyle(HerdrTheme.mauve)
                        }
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(machine.online ? HerdrTheme.signal : HerdrTheme.muted)

                    if isExpanded { detail }
                }
                .padding(14)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(machine.displayName), \(machine.kind.label)")
        .accessibilityValue("\(machine.statusLabel), \(machine.countSummary)")
        .accessibilityHint(isExpanded ? "Hides this machine's breakdown" : "Shows this machine's breakdown")
        .accessibilityAddTraits(isExpanded ? .isSelected : [])
        .accessibilityIdentifier("fleet-machine-card-\(machine.role.rawValue)")
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(HerdrTheme.surface)

            categoryRow(.skills, count: machine.skillsCount)
            categoryRow(.piExtensions, count: machine.piExtensionsCount)
            categoryRow(.cli, count: machine.cliCount)

            Text(FleetDateFormatting.age(machine.lastSyncAt))
                .font(.caption2.monospaced())
                .foregroundStyle(HerdrTheme.mist)

            if let error, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(HerdrTheme.alert)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .transition(.opacity)
    }

    /// The Mac lays the three category counts out in one row. At phone width
    /// they have to stack, so each gets its own line with the count trailing.
    private func categoryRow(_ category: FleetInventoryCategory, count: Int) -> some View {
        HStack(spacing: 8) {
            Label(category.label, systemImage: category.symbol)
            Spacer(minLength: 8)
            Text("\(count)")
        }
        .font(.caption.monospaced())
        .foregroundStyle(HerdrTheme.mist)
    }
}

private struct FleetStatusMark: View {
    let isOnline: Bool

    var body: some View {
        Circle()
            .fill(isOnline ? HerdrTheme.success : HerdrTheme.muted)
            .frame(width: 8, height: 8)
            .overlay {
                Circle()
                    .strokeBorder(isOnline ? HerdrTheme.success.opacity(0.25) : .clear, lineWidth: 5)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Inventory

private struct FleetCategoryFilterBar: View {
    @Binding var selection: FleetInventoryFilter

    var body: some View {
        HStack(spacing: 0) {
            ForEach(FleetInventoryFilter.allCases) { filter in
                Button {
                    withAnimation(.snappy) { selection = filter }
                } label: {
                    Text(filter.label.lowercased())
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .font(.subheadline.monospaced().bold())
                .foregroundStyle(selection == filter ? HerdrTheme.ink : HerdrTheme.mist)
                .background(selection == filter ? HerdrTheme.accent : HerdrTheme.graphite)
                .overlay {
                    Rectangle().strokeBorder(HerdrTheme.surface.opacity(0.8), lineWidth: 1)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == filter ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inventory category")
        .accessibilityIdentifier("fleet-inventory-filter")
    }
}

/// One row of the Mac's matrix, turned on its side: the item once at the top,
/// then one line per machine.
private struct FleetInventoryCard: View {
    let store: FleetStore
    let item: FleetInventoryItem

    var body: some View {
        GlassCard(radius: HerdrTheme.compactRadius) {
            VStack(alignment: .leading, spacing: 10) {
                itemSummary
                Divider().overlay(HerdrTheme.surface)
                ForEach(store.machines) { machine in
                    FleetMachineStateRow(
                        itemID: item.id,
                        machine: machine,
                        state: store.state(for: item, machineID: machine.id)
                    )
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fleet-inventory-row-\(item.id)")
    }

    private var itemSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: item.category.symbol)
                    .foregroundStyle(categoryColor)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(item.name)
                    .font(.headline.bold())
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(item.category.label)
                    .font(.caption2.monospaced().bold())
                    .foregroundStyle(categoryColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(categoryColor.opacity(0.1), in: Capsule())
            }

            if let summary = item.summary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(HerdrTheme.mist)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let version = item.version {
                Text("v\(version)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(HerdrTheme.muted)
            }
        }
    }

    private var categoryColor: Color {
        switch item.category {
        case .skills: HerdrTheme.mauve
        case .piExtensions: HerdrTheme.signal
        case .cli: HerdrTheme.accent
        }
    }
}

/// The Mac's matrix cell, minus every action control. State always reads as an
/// icon *and* a word, so it survives Differentiate Without Color — which is
/// what the Mac's dashed-trace treatment was for.
private struct FleetMachineStateRow: View {
    let itemID: String
    let machine: FleetMachineSnapshot
    let state: FleetMachineItemState

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(machine.displayName)
                .font(.caption.monospaced().bold())
                .foregroundStyle(HerdrTheme.muted)
                .frame(width: 84, alignment: .leading)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: symbol(for: state.state))
                        .foregroundStyle(color(for: state.state))
                    Text(state.state.label)
                        .font(.caption.monospaced().bold())
                        .foregroundStyle(color(for: state.state))
                    if let version = state.version {
                        Text("v\(version)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(HerdrTheme.muted)
                    }
                    if state.drift {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(HerdrTheme.mauve)
                            .accessibilityLabel("Drift detected")
                    }
                }

                if let badge = ownershipBadge(for: state) {
                    Label(badge.label, systemImage: badge.symbol)
                        .font(.caption2.monospaced().bold())
                        .foregroundStyle(badge.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(badge.color.opacity(0.1), in: Capsule())
                }

                if let auth = state.auth {
                    Label(authLabel(auth), systemImage: authSymbol(auth))
                        .font(.caption2.monospaced())
                        .foregroundStyle(authColor(auth))
                }
            }

            Spacer(minLength: 0)
        }
        .opacity(machine.online ? 1 : 0.62)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fleet-cell-\(itemID)-\(machine.role.rawValue)")
    }

    // The following five helpers are ported verbatim from the Mac's
    // FleetMachineInventoryCell.

    private func authLabel(_ auth: FleetAuthStatus) -> String {
        if auth.configured == true { return "Auth ready" }
        if auth.configured == false { return "Auth required" }
        return auth.checkAvailable == false ? "Auth unavailable" : "Auth not checked"
    }

    private func authSymbol(_ auth: FleetAuthStatus) -> String {
        if auth.configured == true { return "checkmark.shield.fill" }
        if auth.configured == false { return "lock.shield" }
        return auth.checkAvailable == false ? "nosign" : "questionmark.shield"
    }

    private func authColor(_ auth: FleetAuthStatus) -> Color {
        if auth.configured == true { return HerdrTheme.success }
        if auth.configured == false { return HerdrTheme.warning }
        return HerdrTheme.muted
    }

    private func ownershipBadge(for state: FleetMachineItemState) -> (label: String, symbol: String, color: Color)? {
        if state.ownership == .external {
            return ("External · Read only", "lock.fill", HerdrTheme.warning)
        }
        // "Manage" here names what the *Mac* can do with this item; iPhone
        // only reports it. The Mac's badge says just "Manage", which on a
        // phone would promise a control that is not there.
        if state.canAdopt && state.ownership == .unmanaged {
            return ("Matching copy · Manage on Mac", "hand.raised.fill", HerdrTheme.signal)
        }
        if state.ownership == .unmanaged && state.state != .missing {
            return ("Unmanaged · Read only", "lock", HerdrTheme.muted)
        }
        if state.ownership == .managed {
            return ("Managed", "checkmark.shield", HerdrTheme.success)
        }
        return nil
    }

    private func symbol(for state: FleetInstallState) -> String {
        switch state {
        case .installed: "checkmark.circle.fill"
        case .missing: "circle.dashed"
        case .outdated, .drifted: "arrow.up.circle.fill"
        case .unknown: "questionmark.circle"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    private func color(for state: FleetInstallState) -> Color {
        switch state {
        case .installed: HerdrTheme.success
        case .missing, .unknown: HerdrTheme.muted
        case .outdated, .drifted: HerdrTheme.warning
        case .failed: HerdrTheme.alert
        }
    }
}

private enum FleetDateFormatting {
    static func age(_ value: String?) -> String {
        guard let value,
              let date = ISO8601DateFormatter().date(from: value)
        else { return "Not synced yet" }
        let seconds = max(0, Date.now.timeIntervalSince(date))
        if seconds < 60 { return "Synced just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Synced \(formatter.localizedString(for: date, relativeTo: .now))"
    }
}
