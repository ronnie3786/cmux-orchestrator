import SwiftUI

struct HeadlessAgentView: View {
    @Bindable var model: HerdrAppModel
    let openPane: (HerdrPane) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var controller = HeadlessAgentController()
    @State private var prompt = ""
    @State private var selectedMachineID = ""
    @State private var promotionWorkspaceID = ""
    @FocusState private var isPromptFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                HerdrBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        intro
                        if controller.run == nil {
                            promptForm
                        } else {
                            runContent
                        }
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Agent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(controller.isRunning ? "Stop and Close" : "Close") {
                        Task {
                            await controller.close(model: model)
                            dismiss()
                        }
                    }
                    .disabled(controller.isSubmitting || controller.isPromoting)
                }
            }
        }
        .frame(minWidth: 680, minHeight: 600)
        .interactiveDismissDisabled(controller.isRunning)
        .task {
            if selectedMachineID.isEmpty {
                selectedMachineID = preferredMachineID ?? ""
            }
            isPromptFocused = true
        }
        .onChange(of: selectedMachineID) { _, _ in
            promotionWorkspaceID = ""
        }
        .onDisappear {
            Task { await controller.discard(model: model) }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Ask once, keep your sidebar quiet", systemImage: "sparkles")
                .herdrFont(.title2, weight: .bold)
                .foregroundStyle(HerdrTheme.text)
            Text("Agent runs a private Pi question from your home folder. It only becomes a Herdr chat when you choose Continue as chat.")
                .herdrFont(.body)
                .foregroundStyle(HerdrTheme.mist)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var promptForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.machines.count > 1 {
                Picker("Run on", selection: $selectedMachineID) {
                    ForEach(model.machines) { machine in
                        Text(machine.name).tag(machine.id)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("agent-machine-picker")
            }

            TextField(
                "Ask a question, or ask what needs attention in your Herdr panes…",
                text: $prompt,
                axis: .vertical
            )
            .lineLimit(5...10)
            .focused($isPromptFocused)
            .textFieldStyle(.plain)
            .herdrFont(.body)
            .padding(14)
            .background(HerdrTheme.graphite)
            .overlay {
                RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                    .strokeBorder(isPromptFocused ? HerdrTheme.accent : HerdrTheme.surface, lineWidth: 1)
            }
            .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
            .accessibilityIdentifier("agent-prompt")
            .onSubmit(submit)

            HStack {
                Text("Runs from ~ with investigative CLI access and a current Herdr fleet summary.")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.muted)
                Spacer()
                Button("Ask Agent", systemImage: "arrow.up.circle.fill", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("agent-submit")
            }

            errorBanner
        }
        .padding(18)
        .background(HerdrTheme.elevated.opacity(0.42))
        .clipShape(.rect(cornerRadius: HerdrTheme.cardRadius))
    }

    @ViewBuilder
    private var runContent: some View {
        if let run = controller.run {
            VStack(alignment: .leading, spacing: 14) {
                Label(run.status.label, systemImage: statusSymbol(for: run.status))
                    .herdrFont(.headline, monospaced: true, weight: .bold)
                    .foregroundStyle(statusColor(for: run.status))

                VStack(alignment: .leading, spacing: 6) {
                    Text("YOU ASKED")
                        .herdrFont(.caption, monospaced: true, weight: .bold)
                        .foregroundStyle(HerdrTheme.muted)
                    Text(run.prompt)
                        .herdrFont(.body)
                        .foregroundStyle(HerdrTheme.text)
                        .textSelection(.enabled)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HerdrTheme.elevated.opacity(0.55))
                .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))

                if controller.isRunning {
                    HStack(spacing: 10) {
                        ProgressView().tint(HerdrTheme.accent)
                        Text("Pi is working from your home folder…")
                            .herdrFont(.subheadline)
                            .foregroundStyle(HerdrTheme.mist)
                        Spacer()
                        Button("Cancel", role: .destructive) {
                            Task { await controller.cancel(model: model) }
                        }
                        .accessibilityIdentifier("agent-cancel")
                    }
                    .padding(.vertical, 8)
                }

                if let response = run.response, !response.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("ANSWER")
                                .herdrFont(.caption, monospaced: true, weight: .bold)
                                .foregroundStyle(HerdrTheme.muted)
                            Spacer()
                            if let cost = run.costUSD {
                                Text(cost, format: .currency(code: "USD"))
                                    .herdrFont(.caption, monospaced: true)
                                    .foregroundStyle(HerdrTheme.mist)
                            }
                        }
                        PiMarkdownMessageView(source: response, isStreaming: false, id: "agent-\(run.id)")
                            .textSelection(.enabled)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(HerdrTheme.graphite)
                    .overlay {
                        RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                            .strokeBorder(HerdrTheme.surface, lineWidth: 1)
                    }
                    .clipShape(.rect(cornerRadius: HerdrTheme.cardRadius))
                    .accessibilityIdentifier("agent-response")
                }

                if let message = run.error, !message.isEmpty {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .herdrFont(.subheadline)
                        .foregroundStyle(HerdrTheme.alert)
                        .textSelection(.enabled)
                }

                errorBanner
                terminalActions(for: run)
            }
        }
    }

    @ViewBuilder
    private func terminalActions(for run: HeadlessAgentRun) -> some View {
        if run.status.isTerminal {
            HStack(spacing: 10) {
                Button("Ask another", systemImage: "arrow.counterclockwise") {
                    Task {
                        await controller.discard(model: model)
                        prompt = ""
                        isPromptFocused = true
                    }
                }
                .disabled(controller.isPromoting)

                Spacer()

                if controller.canPromote {
                    Picker("Continue in", selection: $promotionWorkspaceID) {
                        Text("Quick chats").tag("")
                        ForEach(promotionWorkspaces) { workspace in
                            Text(workspace.label).tag(workspace.workspaceID)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 210)
                    .accessibilityIdentifier("agent-promotion-workspace")

                    Button("Continue as chat", systemImage: "bubble.left.and.bubble.right") {
                        Task {
                            let workspaceID = promotionWorkspaceID.isEmpty ? nil : promotionWorkspaceID
                            if let pane = await controller.promote(workspaceID: workspaceID, model: model) {
                                openPane(pane)
                                dismiss()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.isPromoting)
                    .accessibilityIdentifier("agent-promote")
                }
            }
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = controller.errorMessage, !message.isEmpty {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .herdrFont(.subheadline)
                .foregroundStyle(HerdrTheme.alert)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HerdrTheme.alert.opacity(0.1))
                .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
        }
    }

    private var preferredMachineID: String? {
        if case let .machine(id) = model.machineScope { return id }
        if let selectedPane = model.pane(id: model.selectedPaneID) { return selectedPane.machineID }
        if let selectedWorkspace = model.workspace(id: model.selectedWorkspaceID) { return selectedWorkspace.machineID }
        return model.machines.first?.id
    }

    private var promotionWorkspaces: [HerdrWorkspace] {
        model.workspaces
            .filter { $0.machineID == selectedMachineID }
            .sorted { $0.number < $1.number }
    }

    private var canSubmit: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !selectedMachineID.isEmpty
            && !controller.isRunning
    }

    private func submit() {
        guard canSubmit else { return }
        Task { await controller.submit(prompt: prompt, machineID: selectedMachineID, model: model) }
    }

    private func statusSymbol(for status: HeadlessAgentRunStatus) -> String {
        switch status {
        case .queued: "clock"
        case .running: "sparkles"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        case .promoted: "bubble.left.and.bubble.right.fill"
        }
    }

    private func statusColor(for status: HeadlessAgentRunStatus) -> Color {
        switch status {
        case .queued, .running: HerdrTheme.working
        case .completed, .promoted: HerdrTheme.success
        case .failed: HerdrTheme.alert
        case .cancelled: HerdrTheme.mist
        }
    }
}
