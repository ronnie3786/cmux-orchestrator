import SwiftUI
import UniformTypeIdentifiers

struct CreateWorkspaceView: View {
    let create: (String, String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var cwd = ""
    @State private var isCreating = false
    @State private var isChoosingFolder = false
    @FocusState private var focusedField: Field?

    var body: some View {
        NavigationStack {
            Form {
                Section("Workspace") {
                    TextField("Name", text: $label)
                        .focused($focusedField, equals: .label)
                    HStack(spacing: 10) {
                        TextField("Folder path", text: $cwd)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .cwd)
                        Button("Choose…") { isChoosingFolder = true }
                            .accessibilityLabel("Choose folder")
                    }
                }

                Section {
                    Label("Herdr opens one shell pane in this folder. Split panes or start an agent after it appears.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New workspace")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: dismiss.callAsFunction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            isCreating = true
                            if await create(label, cwd) { dismiss() }
                            isCreating = false
                        }
                    }
                    .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || cwd.isEmpty || isCreating)
                }
            }
            .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
                guard case let .success(url) = result else { return }
                cwd = url.path(percentEncoded: false)
            }
            .task { focusedField = .label }
        }
        // Detents are an iOS concept; a Mac sheet needs an explicit size.
        .frame(minWidth: 480, minHeight: 340)
    }
}

private extension CreateWorkspaceView {
    enum Field: Hashable {
        case label
        case cwd
    }
}
