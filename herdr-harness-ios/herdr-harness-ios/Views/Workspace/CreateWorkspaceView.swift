import SwiftUI

struct CreateWorkspaceView: View {
    let create: (String, String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var cwd = ""
    @State private var isCreating = false
    @FocusState private var focusedField: Field?

    var body: some View {
        NavigationStack {
            Form {
                Section("Workspace") {
                    TextField("Name", text: $label)
                        .focused($focusedField, equals: .label)
                    TextField("Folder path", text: $cwd)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .cwd)
                }

                Section {
                    Label("Herdr opens one shell pane in this folder. Split panes or start an agent after it appears.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New workspace")
            .navigationBarTitleDisplayMode(.inline)
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
            .task { focusedField = .label }
        }
    }
}

private extension CreateWorkspaceView {
    enum Field: Hashable {
        case label
        case cwd
    }
}
