import SwiftUI

struct SettingsView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var fontScale: HerdrFontScaleStore
    @Bindable var cleanupSettings: CleanupSettingsStore
    let hudController: HerdrHudController
    @State private var isPresentingMachines = false
    @State private var isPresentingMachineEditor = false
    @State private var editingMachine: HerdrMachine?
    @State private var cleanupCatalog: CleanupModelCatalog?
    @State private var isLoadingCleanupModels = false
    @State private var cleanupModelsError: String?

    var body: some View {
        Form {
            statusSection
            machinesSection
            voiceSection
            alertSection
            hudSection
            cleanupSection
            textSizeSection
            privacySection
            aboutSection
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .scrollContentBackground(.hidden)
        .background(HerdrBackground())
        .sheet(isPresented: $isPresentingMachines) {
            MachinesView(model: model)
                .frame(minWidth: 460, minHeight: 420)
        }
        .sheet(isPresented: $isPresentingMachineEditor) {
            MachineEditorView(model: model, machine: editingMachine)
                .frame(minWidth: 480, minHeight: 420)
        }
        .task { await loadCleanupModels() }
    }

    private var statusSection: some View {
        Section {
            LabeledContent("Server") {
                ConnectionPill(state: model.connectionState)
            }
            LabeledContent("Workspaces", value: "\(model.workspaces.count)")
            LabeledContent("Live panes", value: "\(model.paneCount)")
            LabeledContent(
                "Machines",
                value: "\(model.machines.count) \(model.machines.count == 1 ? "machine" : "machines") · \(liveMachineCount) live"
            )
            if let lastSyncedAt = model.lastSyncedAt {
                LabeledContent("Last update") {
                    Text(lastSyncedAt, style: .relative)
                }
            }
        } header: {
            Label("Connection", systemImage: "bolt.horizontal.circle")
        }
    }

    private var machinesSection: some View {
        Section {
            ForEach(model.machines) { machine in
                Button {
                    editingMachine = machine
                    isPresentingMachineEditor = true
                } label: {
                    HStack(spacing: 10) {
                        MachineListRow(
                            machine: machine,
                            state: model.connectionState(forMachine: machine.id)
                        )
                        Spacer()
                        Image(systemName: "chevron.right")
                            .herdrFont(.caption, weight: .bold)
                            .foregroundStyle(HerdrTheme.muted)
                    }
                    .frame(minHeight: HerdrTheme.minHitTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-machine-row-\(machine.id)")
            }

            Button {
                editingMachine = nil
                isPresentingMachineEditor = true
            } label: {
                Label("add machine", systemImage: "plus")
            }
            .accessibilityIdentifier("settings-add-machine")

            Button("Manage machines", systemImage: "server.rack") {
                isPresentingMachines = true
            }
            .accessibilityIdentifier("settings-manage-machines")

            if model.isDemoMode {
                Button("Connect a real server", systemImage: "server.rack", action: model.leaveDemo)
            } else {
                Button("Use demo data", systemImage: "sparkles", action: model.useDemo)
            }
        } header: {
            Label("Machines", systemImage: "server.rack")
        } footer: {
            Text("Use the private HTTPS address created by Tailscale Serve. Each bearer token is stored in Keychain and sent only to its machine.")
        }
    }

    private var liveMachineCount: Int {
        model.machines.count(where: { model.connectionState(forMachine: $0.id) == .live })
    }

    private var alertSection: some View {
        Section {
            Toggle("Smart agent alerts", systemImage: "bell.badge", isOn: $model.smartAlertsEnabled)
                .onChange(of: model.smartAlertsEnabled) { oldValue, newValue in
                    guard oldValue != newValue else { return }
                    Task { await model.setSmartAlerts(newValue) }
                }

            LabeledContent("Delivery") {
                Text(model.remotePushStatusText)
                    .foregroundStyle(model.remotePushDeliveryVerified ? HerdrTheme.signal : .secondary)
                    .multilineTextAlignment(.trailing)
            }

            Button("Test on this Mac", systemImage: "bell.and.waves.left.and.right") {
                Task { await NotificationManager.postTest() }
            }
            .disabled(!model.smartAlertsEnabled)
        } header: {
            Text("Attention")
        } footer: {
            Text("Herdr alerts only on meaningful transitions: an agent is blocked or background work is ready to review. This Mac stays connected to the event stream, so alerts are delivered locally.")
        }
    }

    private var voiceSection: some View {
        Section {
            Toggle(
                "Prefer Private Parakeet",
                systemImage: "waveform.badge.magnifyingglass",
                isOn: $model.preferPrivateTranscription
            )
            .onChange(of: model.preferPrivateTranscription) { oldValue, newValue in
                guard oldValue != newValue else { return }
                model.setPreferPrivateTranscription(newValue)
            }

            LabeledContent("Fallback", value: "Apple Speech")
        } header: {
            Text("Voice to prompt")
        } footer: {
            Text("Parakeet audio travels only through your authenticated Herdr server and private cmux proxy. If it is unavailable, Herdr transcribes with Apple Speech. Transcripts remain editable and are never sent automatically.")
        }
    }

    private var hudSection: some View {
        Section {
            Toggle(
                "Enable HUD",
                systemImage: "sparkles",
                isOn: Binding(
                    get: { hudController.isEnabled },
                    set: { hudController.setEnabled($0) }
                )
            )

            LabeledContent("Summon", value: "⌃⌥Space")
        } header: {
            Text("HUD")
        } footer: {
            Text("The HUD can run real commands on the selected machine.")
        }
    }

    private var textSizeSection: some View {
        Section {
            Picker("Text size", selection: $fontScale.scale) {
                ForEach(HerdrFontScale.allCases) { scale in
                    Text(scale.label).tag(scale)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings-text-size-picker")

            Text("the quick agent jumps over the lazy herd")
                .font(HerdrTheme.scaled(.caption, scale: fontScale.scale, monospaced: true))
                .foregroundStyle(HerdrTheme.mist)
                .accessibilityIdentifier("settings-text-size-preview")
        } header: {
            HerdrSectionLabel(title: "text size")
        } footer: {
            Text("Applies across Herdr's windows and menu bar.")
        }
    }

    private var cleanupSection: some View {
        Section {
            LabeledContent("Judge model") {
                Menu {
                    if isLoadingCleanupModels {
                        ProgressView()
                    } else if let cleanupModelsError {
                        Text(cleanupModelsError).disabled(true)
                        Button("Retry") { Task { await loadCleanupModels() } }
                            .accessibilityIdentifier("settings-cleanup-model-retry")
                    } else if let cleanupCatalog, !cleanupCatalog.models.isEmpty {
                        ForEach(groupedCleanupProviders, id: \.self) { provider in
                            Section(provider) {
                                ForEach(cleanupModelsByProvider[provider] ?? []) { candidate in
                                    Button {
                                        cleanupSettings.model = candidate.id
                                    } label: {
                                        Label(
                                            candidate.displayName,
                                            systemImage: selectedCleanupModel == candidate.id ? "checkmark.circle.fill" : "cpu"
                                        )
                                    }
                                }
                            }
                        }
                    } else {
                        Text("No models available").disabled(true)
                        Button("Retry") { Task { await loadCleanupModels() } }
                            .accessibilityIdentifier("settings-cleanup-model-retry")
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "cpu")
                        Text(selectedCleanupModel)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .herdrFont(.caption2)
                    }
                    .herdrFont(.caption, weight: .semibold)
                    .foregroundStyle(HerdrTheme.accent)
                    .frame(minHeight: HerdrTheme.minHitTarget)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("settings-cleanup-model-picker")
            }

            Picker("Thinking level", selection: $cleanupSettings.thinkingLevel) {
                ForEach(CleanupThinkingLevel.allCases) { level in
                    Text(level.label).tag(level)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("settings-cleanup-thinking-picker")

            TextField(
                "Cost flag threshold",
                value: $cleanupSettings.costThresholdUSD,
                format: .number.precision(.fractionLength(2))
            )
            .accessibilityIdentifier("settings-cleanup-cost-threshold")
        } header: {
            Text("Smart Cleanup")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sessions at or above this reported cost are flagged in cleanup reports. Pane content is sent to whichever judge model you pick, a cloud model uploads pane text to that provider, while the local custom-lux-dspark model keeps it on this machine's tailnet.")
                Text("Smart Cleanup \(CleanupFeature.version)")
                    .herdrFont(.caption2)
                    .foregroundStyle(HerdrTheme.muted)
            }
        }
    }

    private var cleanupModelsByProvider: [String: [CleanupAvailableModel]] {
        Dictionary(grouping: cleanupCatalog?.models ?? [], by: \.provider)
    }

    private var groupedCleanupProviders: [String] { cleanupModelsByProvider.keys.sorted() }

    private var selectedCleanupModel: String {
        if !cleanupSettings.model.isEmpty { return cleanupSettings.model }
        if let fullID = cleanupCatalog?.defaultModel?.fullID { return fullID }
        return "Server default"
    }

    private func loadCleanupModels() async {
        guard !isLoadingCleanupModels else { return }
        isLoadingCleanupModels = true
        cleanupModelsError = nil
        do {
            cleanupCatalog = try await model.fetchCleanupModels()
        } catch {
            cleanupModelsError = error.localizedDescription
        }
        isLoadingCleanupModels = false
    }

    private var privacySection: some View {
        Section {
            Label("The raw Herdr socket never leaves your Mac", systemImage: "lock.shield")
            Label("Terminal control requires your pairing token", systemImage: "key.horizontal")
            Label("Tailscale keeps the server inside your tailnet", systemImage: "network.badge.shield.half.filled")

            Toggle(
                "Show session titles in menu bar",
                systemImage: "eye",
                isOn: $model.showSessionTitles
            )
            .onChange(of: model.showSessionTitles) { oldValue, newValue in
                guard oldValue != newValue else { return }
                model.setShowSessionTitles(newValue)
            }
        } header: {
            Text("Private by design")
        } footer: {
            Text("The menu bar is visible in screen shares, recordings, and screenshots.")
        }
        .herdrFont(.subheadline)
    }

    private var aboutSection: some View {
        Section {
            HStack(spacing: 13) {
                HerdrBrandMark(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Herdr")
                        .herdrFont(.headline, weight: .bold)
                    Text("Remote command deck · 0.1")
                        .herdrFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
