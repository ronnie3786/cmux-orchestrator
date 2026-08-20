import SwiftUI

struct SettingsView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var fontScale: HerdrFontScaleStore

    var body: some View {
        Form {
            statusSection
            connectionSection
            voiceSection
            alertSection
            textSizeSection
            privacySection
            aboutSection
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .scrollContentBackground(.hidden)
        .background(HerdrBackground())
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

    private var privacySection: some View {
        Section("Private by design") {
            Label("The raw Herdr socket never leaves your Mac", systemImage: "lock.shield")
            Label("Terminal control requires your pairing token", systemImage: "key.horizontal")
            Label("Tailscale keeps the server inside your tailnet", systemImage: "network.badge.shield.half.filled")
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
