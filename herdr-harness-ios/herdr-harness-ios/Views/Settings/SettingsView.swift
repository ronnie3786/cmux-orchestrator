import SwiftUI

struct SettingsView: View {
    @Bindable var model: HerdrAppModel

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                connectionSection
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
            if let lastUpdated = model.lastUpdated {
                LabeledContent("Last update") {
                    Text(lastUpdated, style: .relative)
                }
            }
        } header: {
            Label("Connection", systemImage: "bolt.horizontal.circle")
        }
    }

    private var connectionSection: some View {
        Section {
            TextField("Server URL", text: $model.serverURLString)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SecureField("Pairing token", text: $model.apiToken)
                .textContentType(.password)

            Button("Save and reconnect", systemImage: "arrow.trianglehead.2.clockwise.rotate.90", action: model.connect)

            if model.isDemoMode {
                Button("Connect a real server", systemImage: "server.rack", action: model.leaveDemo)
            } else {
                Button("Use demo data", systemImage: "sparkles", action: model.useDemo)
            }
        } footer: {
            Text("Use the private HTTPS address created by Tailscale Serve. The bearer token is stored in Keychain and sent only to this server.")
        }
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
