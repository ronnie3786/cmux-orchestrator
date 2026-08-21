import SwiftUI

struct MachineEditorView: View {
    @Bindable var model: HerdrAppModel
    let machine: HerdrMachine?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var urlString: String
    @State private var token: String
    @State private var testState: TestState = .idle
    @State private var validationMessage: String?
    @State private var isPresentingDeleteConfirmation = false

    init(model: HerdrAppModel, machine: HerdrMachine?) {
        self.model = model
        self.machine = machine
        _name = State(initialValue: machine?.name ?? "")
        _urlString = State(initialValue: machine?.urlString ?? "")
        _token = State(initialValue: machine.map { KeychainStore.value(for: "api-token.\($0.id)") } ?? "")
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("auto from server", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("Connection") {
                TextField("Server URL", text: $urlString)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Pairing token", text: $token)
                    .textContentType(.password)
            }

            Section {
                Button(action: testConnection) {
                    HStack {
                        Text("Test connection")
                        Spacer()
                        if testState == .testing { ProgressView() }
                    }
                }
                .disabled(testState == .testing)
                .accessibilityIdentifier("machine-editor-test-connection")

                testResult
            }

            if let validationMessage {
                Section {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(HerdrTheme.alert)
                }
            }

            if machine != nil {
                Section {
                    Button("Remove machine", role: .destructive) {
                        isPresentingDeleteConfirmation = true
                    }
                    .accessibilityIdentifier("machine-editor-remove")
                }
            }
        }
        .navigationTitle(machine == nil ? "Add machine" : "Edit machine")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .accessibilityIdentifier("machine-editor-save")
            }
        }
        .confirmationDialog(
            "Remove \(machine?.name ?? "machine")? Sessions stay on the machine; this only removes the connection.",
            isPresented: $isPresentingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove machine", role: .destructive) {
                guard let machine else { return }
                model.removeMachine(id: machine.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    @ViewBuilder
    private var testResult: some View {
        switch testState {
        case .idle, .testing:
            EmptyView()
        case let .success(hostname):
            Label("Connected · \(hostname)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(HerdrTheme.signal)
        case let .failure(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(HerdrTheme.alert)
        }
    }

    private func testConnection() {
        guard let configuration = ServerConfiguration(urlString: urlString, token: token) else {
            testState = .failure("Enter a valid https:// (or http://localhost) URL.")
            return
        }
        testState = .testing
        Task {
            let client = HerdrAPIClient(configuration: configuration)
            do {
                _ = try await client.fetchHealthProbe()
                let network = try await client.fetchNetworkInfo()
                let hostname = displayHostname(network: network, fallbackURL: configuration.baseURL)
                if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let autoName = network.tailscaleDNSName.split(separator: ".").first.map(String.init)
                        ?? network.hostname.split(separator: ".").first.map(String.init)
                    if let autoName, !autoName.isEmpty { name = autoName }
                }
                testState = .success(hostname: hostname)
            } catch let error as APIError {
                if case let .server(status, _) = error, status == 401 {
                    testState = .failure("Token rejected")
                } else {
                    testState = .failure("Unreachable")
                }
            } catch {
                testState = .failure("Unreachable")
            }
        }
    }

    private func save() {
        guard ServerConfiguration(urlString: urlString, token: token) != nil else {
            validationMessage = "Enter a valid https:// (or http://localhost) URL."
            return
        }
        let saved: Bool
        if let machine {
            saved = model.updateMachine(id: machine.id, name: name, urlString: urlString, token: token)
        } else {
            saved = model.addMachine(name: name, urlString: urlString, token: token)
        }
        if saved { dismiss() }
        else { validationMessage = model.errorMessage }
    }

    private func displayHostname(network: NetworkInfoResponse, fallbackURL: URL) -> String {
        let preferred = network.tailscaleDNSName.split(separator: ".").first.map(String.init)
            ?? network.hostname.split(separator: ".").first.map(String.init)
        return preferred?.isEmpty == false ? preferred! : (fallbackURL.host ?? fallbackURL.absoluteString)
    }
}

private enum TestState: Equatable {
    case idle
    case testing
    case success(hostname: String)
    case failure(String)
}
