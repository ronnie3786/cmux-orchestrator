import AVFoundation
import Combine
import ComposableArchitecture
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var store: StoreOf<HarnessFeature>

    var body: some View {
        NavigationStack {
            Form {
                if store.isDemoMode {
                    Section("Demo Mode") {
                        Text("You are viewing simulated sessions stored locally on this iPhone. No commands are being sent to a Mac.")
                            .foregroundStyle(.secondary)

                        Button("Connect Real Server") {
                            store.send(.exitDemoModeTapped)
                        }
                    }
                }

                Section("Active Source") {
                    if store.serverSources.isEmpty {
                        Text("Add a CMUX server URL to connect this iPhone to a session source.")
                            .foregroundStyle(.secondary)
                    } else {
                        Menu {
                            ForEach(store.serverSources) { source in
                                Button {
                                    store.send(.selectServerSource(source.id))
                                } label: {
                                    Label(
                                        source.name,
                                        systemImage: source.id == store.selectedServerSourceID ? "checkmark.circle.fill" : "server.rack"
                                    )
                                }
                            }
                        } label: {
                            HStack {
                                Label(store.activeServerSourceName, systemImage: "server.rack")
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if !store.activeServerSourceURLString.isEmpty {
                            Text(store.activeServerSourceURLString)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }

                Section(store.isEditingSavedServerSource ? "Source Details" : "New Source") {
                    TextField("Name", text: $store.serverSourceNameString)
                        .textInputAutocapitalization(.words)

                    TextField("Server URL", text: $store.serverURLString)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()

                    Button {
                        store.send(.saveServerTapped)
                    } label: {
                        Label(
                            store.isEditingSavedServerSource ? "Save Source" : "Add Source",
                            systemImage: "checkmark.circle.fill"
                        )
                    }

                    if store.isEditingSavedServerSource {
                        Button {
                            store.send(.newServerSourceTapped)
                        } label: {
                            Label("Add Another Source", systemImage: "plus.circle")
                        }
                    }
                }

                if !store.serverSources.isEmpty {
                    Section("Saved Sources") {
                        ForEach(store.serverSources) { source in
                            ServerSourceSettingsRow(store: store, source: source)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        store.send(.dismissSettings)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.send(.saveServerTapped)
                    }
                    .disabled(store.serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct ServerSourceSettingsRow: View {
    @Bindable var store: StoreOf<HarnessFeature>
    let source: HarnessServerSource

    var body: some View {
        HStack(spacing: 12) {
            Button {
                store.send(.selectServerSource(source.id))
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(source.urlString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            if source.id == store.selectedServerSourceID {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Selected")
            }

            Menu("Actions", systemImage: "ellipsis.circle") {
                Button {
                    store.send(.selectServerSource(source.id))
                } label: {
                    Label("Use Source", systemImage: "checkmark.circle")
                }

                Button {
                    store.send(.editServerSource(source.id))
                } label: {
                    Label("Edit Source", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    store.send(.deleteServerSource(source.id))
                } label: {
                    Label("Delete Source", systemImage: "trash")
                }
            }
            .menuStyle(.button)
        }
    }
}

struct NewSessionView: View {
    @Bindable var store: StoreOf<HarnessFeature>

    var body: some View {
        NavigationStack {
            Form {
                Section("Session") {
                    Picker("Mode", selection: $store.newSessionMode) {
                        ForEach(NewSessionMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField("Project path", text: $store.newSessionProjectPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if store.newSessionMode == .shell {
                        TextField("Name", text: $store.newSessionName)
                            .textInputAutocapitalization(.words)
                    }
                }

                if store.newSessionMode == .claude {
                    Section("Worktree") {
                        TextField(
                            "JIRA URL",
                            text: Binding(
                                get: { store.newSessionJiraURL },
                                set: { store.send(.newSessionJiraChanged($0)) }
                            )
                        )
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()

                        TextField("Branch", text: $store.newSessionBranchName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Section("Prompt") {
                        TextField("Initial prompt", text: $store.newSessionPrompt, axis: .vertical)
                            .lineLimit(4...10)
                    }
                }

                if let error = store.newSessionError {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        store.send(.dismissNewSession)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(store.isCreatingSession ? "Creating" : "Create") {
                        store.send(.createNewSession)
                    }
                    .disabled(store.isCreatingSession)
                }
            }
        }
    }
}
