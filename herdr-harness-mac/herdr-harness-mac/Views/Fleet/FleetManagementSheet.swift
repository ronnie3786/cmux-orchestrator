import SwiftUI

struct FleetManagementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var store: FleetStore
    @State private var selectedMachineID: String?
    @State private var pendingRemoval: FleetRemovalRequest?
    /// Fleet is a destination in the detail column, not a sheet. Embedded it
    /// fills whatever the window gives it and drops the Done button, because
    /// there is nothing to dismiss — the segmented picker moves you on.
    private let isEmbedded: Bool

    init(
        model: HerdrAppModel,
        initiallySelectedMachineID: String? = nil,
        isEmbedded: Bool = false
    ) {
        _store = State(initialValue: FleetStore(model: model))
        _selectedMachineID = State(initialValue: initiallySelectedMachineID)
        self.isEmbedded = isEmbedded
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(HerdrTheme.surface.opacity(0.7))

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    constellationSection
                    inventorySection
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 26)
            }
            .scrollIndicators(.automatic)
        }
        .frame(
            minWidth: isEmbedded ? nil : 940,
            idealWidth: isEmbedded ? nil : 1_180,
            maxWidth: .infinity,
            minHeight: isEmbedded ? nil : 680,
            idealHeight: isEmbedded ? nil : 820,
            maxHeight: isEmbedded ? .infinity : nil
        )
        .background(HerdrTheme.ink)
        .tint(HerdrTheme.signal)
        .accessibilityIdentifier("fleet-management-sheet")
        .task {
            await store.refresh()
        }
        .confirmationDialog(
            "Remove item?",
            isPresented: removalDialogIsPresented,
            titleVisibility: .visible
        ) {
            if let pendingRemoval {
                Button("Remove \(pendingRemoval.itemName)", role: .destructive) {
                    let request = pendingRemoval
                    self.pendingRemoval = nil
                    Task {
                        await store.perform(
                            .remove,
                            itemID: request.itemID,
                            machineID: request.machineID
                        )
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            if let pendingRemoval {
                Text("This removes the managed item from \(pendingRemoval.machineName). External items stay read-only.")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(HerdrTheme.signal.opacity(0.14))
                    .frame(width: 34, height: 34)
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(HerdrTheme.signal)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Fleet")
                    .herdrFont(.title3, weight: .bold)
                    .foregroundStyle(HerdrTheme.text)
                Text(fleetSummary)
                    .herdrFont(.caption, monospaced: true)
                    .foregroundStyle(HerdrTheme.mist)
            }

            Spacer(minLength: 20)

            if let notice = store.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .herdrFont(.caption, weight: .medium)
                    .foregroundStyle(HerdrTheme.success)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }

            if isEmbedded {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await store.refresh() }
                }
                .buttonStyle(.bordered)
                .disabled(store.isLoading)
                .accessibilityIdentifier("fleet-refresh-button")
            } else {
                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("fleet-close-button")
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 18)
        .background(HerdrTheme.graphite.opacity(0.86))
    }

    private var constellationSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Machine constellation")
                        .herdrFont(.headline, weight: .semibold)
                        .foregroundStyle(HerdrTheme.text)
                    Text("A quiet view of where your tools are ready to run.")
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.mist)
                }
                Spacer()
                if store.driftCount > 0 {
                    Label("\(store.driftCount) differences", systemImage: "arrow.triangle.2.circlepath")
                        .herdrFont(.caption, monospaced: true, weight: .medium)
                        .foregroundStyle(HerdrTheme.mauve)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(HerdrTheme.mauve.opacity(0.11), in: Capsule())
                }
            }

            FleetConstellationView(
                machines: store.machines,
                selectedMachineID: $selectedMachineID,
                reduceMotion: reduceMotion
            )
            .frame(minHeight: 228, idealHeight: 248, maxHeight: 280)
            .accessibilityIdentifier("fleet-machine-constellation")
        }
        .padding(20)
        .background(HerdrTheme.graphite, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(HerdrTheme.surface.opacity(0.72), lineWidth: 1)
        }
    }

    private var inventorySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Inventory")
                        .herdrFont(.headline, weight: .semibold)
                        .foregroundStyle(HerdrTheme.text)
                    Text(inventorySummary)
                        .herdrFont(.caption, monospaced: true)
                        .foregroundStyle(HerdrTheme.mist)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        Task { await store.syncAll() }
                    } label: {
                        Label("Sync All", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isSyncing || store.machines.isEmpty)
                    .accessibilityIdentifier("fleet-sync-all-button")

                    Button {
                        Task { await store.refresh() }
                    } label: {
                        Label("Refresh", systemImage: store.isLoading ? "arrow.2.circlepath" : "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.isLoading || store.isSyncing)
                    .accessibilityIdentifier("fleet-refresh-button")
                }
            }

            FleetInventoryControls(store: store)
            FleetInventoryMatrix(
                store: store,
                requestRemoval: { item, machine in
                    pendingRemoval = FleetRemovalRequest(
                        itemID: item.id,
                        itemName: item.name,
                        machineID: machine.id,
                        machineName: machine.displayName
                    )
                }
            )
        }
        .padding(20)
        .background(HerdrTheme.graphite, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(HerdrTheme.surface.opacity(0.72), lineWidth: 1)
        }
    }

    private var fleetSummary: String {
        guard !store.machines.isEmpty else { return "No machines configured" }
        return "\(store.onlineCount) of \(store.machines.count) online"
    }

    private var inventorySummary: String {
        if store.totalItemCount == 0 { return "No inventory reported yet" }
        let differenceText = store.differenceCount == 0 ? "in sync" : "\(store.differenceCount) need attention"
        return "\(store.totalItemCount) items · \(differenceText)"
    }

    private var removalDialogIsPresented: Binding<Bool> {
        Binding(
            get: { pendingRemoval != nil },
            set: { isPresented in
                if !isPresented { pendingRemoval = nil }
            }
        )
    }
}

private struct FleetRemovalRequest: Equatable {
    let itemID: String
    let itemName: String
    let machineID: String
    let machineName: String
}

private struct FleetConstellationView: View {
    let machines: [FleetMachineSnapshot]
    @Binding var selectedMachineID: String?
    let reduceMotion: Bool
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @State private var hoveredMachineID: String?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                FleetCircuitTrace(
                    count: machines.count,
                    activeIndex: activeIndex,
                    reduceMotion: reduceMotion
                )
                .stroke(
                    traceColor,
                    style: StrokeStyle(
                        lineWidth: activeIndex == nil ? 1.5 : 2.2,
                        lineCap: .round,
                        lineJoin: .round,
                        dash: differentiateWithoutColor ? [4, 3] : []
                    )
                )
                .padding(.horizontal, 50)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: activeIndex)

                if machines.isEmpty {
                    VStack(spacing: 9) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 24))
                            .foregroundStyle(HerdrTheme.muted)
                        Text("Add a machine in Settings to start your fleet.")
                            .herdrFont(.callout, weight: .medium)
                            .foregroundStyle(HerdrTheme.mist)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(spacing: 18) {
                        ForEach(machines) { machine in
                            FleetMachineCard(
                                machine: machine,
                                isSelected: selectedMachineID == machine.id,
                                isHovered: hoveredMachineID == machine.id,
                                reduceMotion: reduceMotion,
                                select: {
                                    selectedMachineID = selectedMachineID == machine.id ? nil : machine.id
                                },
                                setHovering: { hovering in
                                    hoveredMachineID = hovering ? machine.id : nil
                                }
                            )
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 2)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
        }
    }

    private var activeIndex: Int? {
        let id = hoveredMachineID ?? selectedMachineID
        guard let id else { return nil }
        return machines.firstIndex(where: { $0.id == id })
    }

    private var traceColor: Color {
        guard activeIndex != nil else { return HerdrTheme.signal.opacity(0.52) }
        return HerdrTheme.signal
    }
}

private struct FleetCircuitTrace: Shape {
    let count: Int
    let activeIndex: Int?
    let reduceMotion: Bool

    func path(in rect: CGRect) -> Path {
        guard count > 1 else { return Path() }
        let step = rect.width / CGFloat(count - 1)
        let centerY = rect.midY
        var path = Path()

        for index in 0..<(count - 1) {
            let startX = CGFloat(index) * step
            let endX = CGFloat(index + 1) * step
            let bend = min(22, rect.height * 0.16)
            let focus = activeIndex == index || activeIndex == index + 1
            let yOffset = focus ? bend * 0.4 : bend

            path.move(to: CGPoint(x: startX, y: centerY))
            path.addLine(to: CGPoint(x: startX + 18, y: centerY))
            path.addLine(to: CGPoint(x: startX + 32, y: centerY - yOffset))
            path.addLine(to: CGPoint(x: endX - 32, y: centerY - yOffset))
            path.addLine(to: CGPoint(x: endX - 18, y: centerY))
            path.addLine(to: CGPoint(x: endX, y: centerY))
        }
        return path
    }
}

private struct FleetMachineCard: View {
    let machine: FleetMachineSnapshot
    let isSelected: Bool
    let isHovered: Bool
    let reduceMotion: Bool
    let select: () -> Void
    let setHovering: (Bool) -> Void

    var body: some View {
        Button(action: select) {
            ZStack(alignment: .topLeading) {
                cardBody
                if isHovered || isSelected {
                    safeOverlay
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 188, maxHeight: 214)
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover(perform: setHovering)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isHovered)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isSelected)
        .accessibilityLabel("\(machine.displayName), \(machine.kind.label)")
        .accessibilityValue("\(machine.statusLabel), \(machine.countSummary)")
        .accessibilityHint("Select to keep this machine highlighted")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("fleet-machine-card-\(machine.role.rawValue)")
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(machine.kind.assetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 76, height: 65)
                    .accessibilityHidden(true)
                Spacer()
                FleetStatusMark(isOnline: machine.online)
            }

            Spacer(minLength: 4)

            VStack(alignment: .leading, spacing: 3) {
                Text(machine.displayName)
                    .herdrFont(.callout, weight: .bold)
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(1)
                Text(machine.kind.label)
                    .herdrFont(.caption, monospaced: true)
                    .foregroundStyle(HerdrTheme.accent)
                HStack(spacing: 7) {
                    Text(machine.statusLabel)
                    Text("·")
                    Text(machine.countSummary)
                }
                .herdrFont(.caption2, monospaced: true)
                .foregroundStyle(machine.online ? HerdrTheme.signal : HerdrTheme.muted)
            }
        }
        .padding(17)
        .background(
            isSelected ? HerdrTheme.elevated : HerdrTheme.graphite.opacity(0.72),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(
                    isSelected ? HerdrTheme.signal.opacity(0.85) : HerdrTheme.surface.opacity(0.82),
                    lineWidth: isSelected ? 1.5 : 1
                )
        }
    }

    private var safeOverlay: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Text(machine.displayName)
                    .herdrFont(.caption, weight: .bold)
                    .foregroundStyle(HerdrTheme.text)
                Spacer()
                Text(machine.kind.label)
                    .herdrFont(.caption2, monospaced: true, weight: .bold)
                    .foregroundStyle(HerdrTheme.accent)
            }
            HStack(spacing: 8) {
                FleetStatusMark(isOnline: machine.online)
                Text(machine.statusLabel)
                    .herdrFont(.caption2, monospaced: true, weight: .medium)
                    .foregroundStyle(machine.online ? HerdrTheme.signal : HerdrTheme.muted)
                Spacer()
                Text(machine.countSummary)
                    .herdrFont(.caption2, monospaced: true)
                    .foregroundStyle(HerdrTheme.mist)
            }
            HStack(spacing: 9) {
                Label("\(machine.skillsCount) skills", systemImage: FleetInventoryCategory.skills.symbol)
                Label("\(machine.piExtensionsCount) extensions", systemImage: FleetInventoryCategory.piExtensions.symbol)
                Label("\(machine.cliCount) CLI", systemImage: FleetInventoryCategory.cli.symbol)
            }
            .labelStyle(.titleAndIcon)
            .herdrFont(.caption2, monospaced: true)
            .foregroundStyle(HerdrTheme.mist)
            HStack(spacing: 8) {
                if machine.driftCount > 0 {
                    Label("\(machine.driftCount) drift", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(HerdrTheme.mauve)
                }
                Spacer()
                Text(FleetDateFormatting.age(machine.lastSyncAt))
                    .herdrFont(.caption2, monospaced: true)
                    .foregroundStyle(HerdrTheme.mist)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(HerdrTheme.elevated.opacity(0.98), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(HerdrTheme.signal.opacity(0.5), lineWidth: 1)
        }
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

private struct FleetInventoryControls: View {
    @Bindable var store: FleetStore
    @FocusState private var searchFieldIsFocused: Bool

    var body: some View {
        HStack(spacing: 14) {
            Picker("Inventory category", selection: $store.selectedFilter) {
                ForEach(FleetInventoryFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 430)
            .accessibilityIdentifier("fleet-inventory-filter")

            Toggle("Differences only", isOn: $store.differencesOnly)
                .toggleStyle(.checkbox)
                .foregroundStyle(HerdrTheme.mist)
                .accessibilityIdentifier("fleet-differences-toggle")

            Spacer(minLength: 6)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(searchFieldIsFocused ? HerdrTheme.signal : HerdrTheme.muted)
                TextField("Search inventory", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFieldIsFocused)
                    .accessibilityIdentifier("fleet-search-field")
                if !store.searchText.isEmpty {
                    Button {
                        store.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(HerdrTheme.muted)
                    .accessibilityLabel("Clear inventory search")
                }
            }
            .padding(.horizontal, 10)
            .frame(width: 220, height: 30)
            .background(HerdrTheme.ink.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(searchFieldIsFocused ? HerdrTheme.signal : HerdrTheme.surface, lineWidth: 1)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct FleetInventoryMatrix: View {
    @Bindable var store: FleetStore
    let requestRemoval: (FleetInventoryItem, FleetMachineSnapshot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            matrixHeader
            Divider().overlay(HerdrTheme.surface)
            if store.isLoading && store.items.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading inventory…")
                        .herdrFont(.callout)
                        .foregroundStyle(HerdrTheme.mist)
                }
                .frame(maxWidth: .infinity, minHeight: 100)
            } else if store.filteredItems.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 22))
                        .foregroundStyle(HerdrTheme.muted)
                    Text(store.items.isEmpty ? "No inventory reported" : "No matching items")
                        .herdrFont(.callout, weight: .semibold)
                        .foregroundStyle(HerdrTheme.text)
                    Text(store.items.isEmpty ? "Refresh a connected machine to see its catalog." : "Try a different filter or search.")
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.mist)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.filteredItems) { item in
                        FleetInventoryRow(store: store, item: item, requestRemoval: requestRemoval)
                        if item.id != store.filteredItems.last?.id {
                            Divider().overlay(HerdrTheme.surface.opacity(0.72))
                        }
                    }
                }
            }
        }
        .background(HerdrTheme.ink.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(HerdrTheme.surface.opacity(0.82), lineWidth: 1)
        }
        .accessibilityIdentifier("fleet-inventory-matrix")
    }

    private var matrixHeader: some View {
        HStack(spacing: 12) {
            Text("Item")
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(store.machines) { machine in
                VStack(alignment: .leading, spacing: 2) {
                    Text(machine.displayName)
                    Text(machine.kind.label)
                }
                .frame(width: 190, alignment: .leading)
            }
        }
        .herdrFont(.caption2, monospaced: true, weight: .bold)
        .foregroundStyle(HerdrTheme.muted)
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
    }
}

private struct FleetInventoryRow: View {
    @Bindable var store: FleetStore
    let item: FleetInventoryItem
    let requestRemoval: (FleetInventoryItem, FleetMachineSnapshot) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            itemSummary
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(store.machines) { machine in
                FleetMachineInventoryCell(
                    store: store,
                    item: item,
                    machine: machine,
                    requestRemoval: requestRemoval
                )
                .frame(width: 190, alignment: .leading)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fleet-inventory-row-\(item.id)")
    }

    private var itemSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: item.category.symbol)
                    .foregroundStyle(categoryColor)
                    .frame(width: 18)
                Text(item.name)
                    .herdrFont(.callout, weight: .semibold)
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(1)
                Text(item.category.label)
                    .herdrFont(.caption2, monospaced: true, weight: .medium)
                    .foregroundStyle(categoryColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(categoryColor.opacity(0.1), in: Capsule())
            }
            if let summary = item.summary {
                Text(summary)
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.mist)
                    .lineLimit(2)
            }
            HStack(spacing: 7) {
                if let version = item.version {
                    Text("v\(version)")
                        .foregroundStyle(HerdrTheme.muted)
                }
            }
            .herdrFont(.caption2, monospaced: true)
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

private struct FleetMachineInventoryCell: View {
    @Bindable var store: FleetStore
    let item: FleetInventoryItem
    let machine: FleetMachineSnapshot
    let requestRemoval: (FleetInventoryItem, FleetMachineSnapshot) -> Void

    var body: some View {
        let state = store.state(for: item, machineID: machine.id)
        let active = store.isActionActive(itemID: item.id, machineID: machine.id)
        let error = store.error(for: item.id, machineID: machine.id)

        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: symbol(for: state.state))
                    .foregroundStyle(color(for: state.state))
                Text(state.state.label)
                    .herdrFont(.caption2, monospaced: true, weight: .medium)
                    .foregroundStyle(color(for: state.state))
                    .lineLimit(1)
                Spacer(minLength: 2)
                if state.drift {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(HerdrTheme.mauve)
                        .help("Difference from the managed catalog")
                        .accessibilityLabel("Drift detected")
                }
            }

            if let version = state.version {
                Text("v\(version)")
                    .herdrFont(.caption2, monospaced: true)
                    .foregroundStyle(HerdrTheme.muted)
            }

            if let ownershipBadge = ownershipBadge(for: state) {
                Label(ownershipBadge.label, systemImage: ownershipBadge.symbol)
                    .herdrFont(.caption2, monospaced: true, weight: .medium)
                    .foregroundStyle(ownershipBadge.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(ownershipBadge.color.opacity(0.1), in: Capsule())
                    .accessibilityLabel(ownershipBadge.label)
            }

            if let auth = state.auth {
                Label(
                    authLabel(auth),
                    systemImage: authSymbol(auth)
                )
                .herdrFont(.caption2, monospaced: true)
                .foregroundStyle(authColor(auth))
                .accessibilityValue(authLabel(auth))
            }

            if active, let progress = store.progress(for: item.id, machineID: machine.id) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(HerdrTheme.signal)
                    .accessibilityValue("\(Int(progress * 100)) percent")
            }

            HStack(spacing: 4) {
                if state.canAdopt && state.ownership == .unmanaged {
                    actionButton(.manage, state: state, active: active)
                } else {
                    actionButton(.install, state: state, active: active)
                }
                actionButton(.update, state: state, active: active)
                actionButton(.authCheck, state: state, active: active)
                Menu {
                    if state.canAdopt && state.ownership == .unmanaged {
                        actionMenuButton(.manage, state: state, active: active)
                    } else {
                        actionMenuButton(.install, state: state, active: active)
                    }
                    actionMenuButton(.update, state: state, active: active)
                    actionMenuButton(.authCheck, state: state, active: active)
                    Divider()
                    actionMenuButton(.remove, state: state, active: active)
                } label: {
                    Image(systemName: "ellipsis")
                        .herdrHitTarget(minWidth: 28, minHeight: 28)
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(HerdrTheme.mist)
                .help("More actions for \(machine.displayName)")
                .accessibilityLabel("More actions for \(item.name) on \(machine.displayName)")
                .accessibilityIdentifier("fleet-actions-\(item.id)-\(machine.role.rawValue)")
            }

            if let error {
                Text(error)
                    .herdrFont(.caption2)
                    .foregroundStyle(HerdrTheme.alert)
                    .lineLimit(2)
            }
        }
        .opacity(machine.online ? 1 : 0.62)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fleet-cell-\(item.id)-\(machine.role.rawValue)")
    }

    @ViewBuilder
    private func actionButton(_ action: FleetAction, state: FleetMachineItemState, active: Bool) -> some View {
        let enabled = isEnabled(action, item: item, state: state, active: active)
        Button {
            if action == .remove {
                requestRemoval(item, machine)
            } else {
                Task { await store.perform(action, itemID: item.id, machineID: machine.id) }
            }
        } label: {
            Image(systemName: action.symbol)
                .herdrHitTarget(minWidth: 28, minHeight: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? color(for: action) : HerdrTheme.muted.opacity(0.45))
        .disabled(!enabled)
        .help(action.label)
        .accessibilityLabel("\(action.label) \(item.name) on \(machine.displayName)")
        .accessibilityIdentifier("fleet-action-\(action.rawValue)-\(item.id)-\(machine.role.rawValue)")
    }

    @ViewBuilder
    private func actionMenuButton(_ action: FleetAction, state: FleetMachineItemState, active: Bool) -> some View {
        let enabled = isEnabled(action, item: item, state: state, active: active)
        Button {
            if action == .remove {
                requestRemoval(item, machine)
            } else {
                Task { await store.perform(action, itemID: item.id, machineID: machine.id) }
            }
        } label: {
            Label(action.label, systemImage: action.symbol)
        }
        .disabled(!enabled)
    }

    private func isEnabled(
        _ action: FleetAction,
        item: FleetInventoryItem,
        state: FleetMachineItemState,
        active: Bool
    ) -> Bool {
        guard machine.online, !active else { return false }
        if action == .remove && state.ownership != .managed { return false }
        if action == .manage { return state.canAdopt && state.ownership == .unmanaged }
        if action == .install {
            guard state.installable == true else { return false }
            return state.ownership != .external
                && (state.state == .missing || state.state == .failed || state.state == .unknown)
        }
        if action == .update {
            return state.ownership == .managed
                && (state.state == .installed || state.state == .outdated || state.state == .drifted)
        }
        if action == .authCheck { return state.authCheckAvailable }
        return true
    }

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
        if state.canAdopt && state.ownership == .unmanaged {
            return ("Matching copy · Manage", "hand.raised.fill", HerdrTheme.signal)
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

    private func color(for action: FleetAction) -> Color {
        switch action {
        case .install: HerdrTheme.signal
        case .manage: HerdrTheme.signal
        case .update: HerdrTheme.accent
        case .remove: HerdrTheme.alert
        case .authCheck: HerdrTheme.mist
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
