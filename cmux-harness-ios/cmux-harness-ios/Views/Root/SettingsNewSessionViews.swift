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

                Section("Server") {
                    TextField("Server URL", text: $store.serverURLString)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
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
                }
            }
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
