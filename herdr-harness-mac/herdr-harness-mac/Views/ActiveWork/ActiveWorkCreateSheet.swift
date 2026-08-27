import SwiftUI

struct ActiveWorkCreateSheet: View {
    let create: (String, String, String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind = "idea"
    @State private var title = ""
    @State private var summary = ""
    @State private var isCreating = false
    @State private var errorMessage: String?
    @FocusState private var isTitleFocused: Bool

    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isCreating
    }

    var body: some View {
        NavigationStack {
            ZStack {
                HerdrBackground()

                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Start something worth tracking", systemImage: "sparkles.rectangle.stack")
                            .herdrFont(.title2, weight: .bold)
                            .fontDesign(.rounded)
                            .foregroundStyle(HerdrTheme.text)
                        Text("Create the durable board record first. Agents, Pi sessions, and Buzz discussions can join it as the route develops.")
                            .herdrFont(.body)
                            .foregroundStyle(HerdrTheme.mist)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Picker("Work kind", selection: $kind) {
                        Text("Feature").tag("feature")
                        Text("Task").tag("task")
                        Text("Idea").tag("idea")
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("active-work-new-kind")

                    VStack(alignment: .leading, spacing: 7) {
                        Text("TITLE")
                            .herdrFont(.caption, monospaced: true, weight: .bold)
                            .foregroundStyle(HerdrTheme.muted)
                        TextField("What are we moving forward?", text: $title)
                            .textFieldStyle(.plain)
                            .herdrFont(.body)
                            .padding(11)
                            .background(HerdrTheme.elevated, in: .rect(cornerRadius: HerdrTheme.compactRadius))
                            .focused($isTitleFocused)
                            .accessibilityIdentifier("active-work-new-title")
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("CONTEXT")
                            .herdrFont(.caption, monospaced: true, weight: .bold)
                            .foregroundStyle(HerdrTheme.muted)
                        TextField("A short brief for the agents that will join later", text: $summary, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(3...6)
                            .herdrFont(.body)
                            .padding(11)
                            .background(HerdrTheme.elevated, in: .rect(cornerRadius: HerdrTheme.compactRadius))
                            .accessibilityIdentifier("active-work-new-summary")
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .herdrFont(.caption, monospaced: true)
                            .foregroundStyle(HerdrTheme.alert)
                    }

                    Spacer(minLength: 0)
                }
                .padding(24)
            }
            .navigationTitle("New Active Work")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: dismiss.callAsFunction)
                        .disabled(isCreating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", systemImage: "arrow.right") {
                        Task { await submit() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreate)
                    .accessibilityIdentifier("active-work-new-submit")
                }
            }
        }
        .frame(minWidth: 500, minHeight: 430)
        .task { isTitleFocused = true }
    }

    @MainActor
    private func submit() async {
        guard canCreate else { return }
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }

        do {
            try await create(
                kind,
                title.trimmingCharacters(in: .whitespacesAndNewlines),
                summary.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            dismiss()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
