import SwiftUI

struct SettingsView: View {
    @Bindable var model: HerdrAppModel

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                machinesSection
                voiceSection
                alertSection
                privacySection
                aboutSection
            }
            .navigationTitle("Settings")
            .scrollContentBackground(.hidden)
            .background(HerdrBackground())
        }
    }

    private var statusSection: some View {
        Section {
            LabeledContent("Server") {
                ConnectionPill(state: model.connectionState)
            }
            LabeledContent("Workspaces", value: "\(model.workspaces.count)")
            LabeledContent("Live panes", value: "\(model.paneCount)")
            LabeledContent("Machines", value: "\(model.machines.count) \(model.machines.count == 1 ? "machine" : "machines") · \(liveMachineCount) live")
            // `lastSyncedAt`, not `lastUpdated`: people read this row as "is
            // this thing still talking to my Mac", and a healthy but quiet
            // connection must not read "3 hours ago".
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
                NavigationLink {
                    MachineEditorView(model: model, machine: machine)
                } label: {
                    MachineListRow(machine: machine, state: model.connectionState(forMachine: machine.id))
                }
                .accessibilityIdentifier("settings-machine-row-\(machine.id)")
            }

            NavigationLink {
                MachineEditorView(model: model, machine: nil)
            } label: {
                Label("add machine", systemImage: "plus")
            }
            .accessibilityIdentifier("settings-add-machine")

            NavigationLink {
                MachinesView(model: model)
            } label: {
                Label("Manage machines", systemImage: "server.rack")
            }
            .accessibilityIdentifier("settings-manage-machines")

            // Fleet is a read-only report about the machines configured above,
            // so it belongs in the same bucket rather than in a fourth tab.
            NavigationLink {
                FleetInventoryView(model: model)
            } label: {
                Label("Fleet inventory", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .accessibilityIdentifier("settings-fleet-inventory")

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

            Toggle(
                "Show session names on Lock Screen and Dynamic Island",
                systemImage: "rectangle.and.text.magnifyingglass",
                isOn: $model.showSessionTitles
            )
            .onChange(of: model.showSessionTitles) { oldValue, newValue in
                guard oldValue != newValue else { return }
                model.setShowSessionTitles(newValue)
            }

            LabeledContent("Delivery") {
                Text(model.remotePushStatusText)
                    .foregroundStyle(model.remotePushDeliveryVerified ? HerdrTheme.signal : .secondary)
                    .multilineTextAlignment(.trailing)
            }

            Button("Test this iPhone locally", systemImage: "bell.and.waves.left.and.right") {
                Task { await NotificationManager.postTest() }
            }
            .disabled(!model.smartAlertsEnabled)
        } header: {
            Text("Attention")
        } footer: {
            Text("Herdr alerts only on meaningful transitions: an agent is blocked or background work is ready to review. Background APNs is reported separately from this local test.")
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

    private var privacySection: some View {
        Section("Private by design") {
            Label("The raw Herdr socket never leaves your Mac", systemImage: "lock.shield")
            Label("Terminal control requires your pairing token", systemImage: "key.horizontal")
            Label("Tailscale keeps the server inside your tailnet", systemImage: "network.badge.shield.half.filled")
        }
        .font(.subheadline)
    }

    private var aboutSection: some View {
        Section {
            HStack(spacing: 13) {
                HerdrBrandMark(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Herdr")
                        .font(.headline.bold())
                    Text("Remote command deck · 0.1")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
