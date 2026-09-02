import SwiftUI

/// One instruction, one headless run. The agent works on a machine and reports
/// back here; nothing appears in the chat list unless the user promotes it.
struct HeadlessAgentSheet: View {
    @Bindable var model: HerdrAppModel
    let machineID: String

    @Environment(\.dismiss) private var dismiss
    @State private var controller = HeadlessAgentController()
    @State private var prompt = ""
    @State private var promotionWorkspaceID = ""
    @State private var agentCatalog: AgentModelCatalogResponse?
    @State private var didLoadAgentCatalog = false
    @State private var modelWarning: String?
    @State private var hapticPulse = HerdrHapticPulse()
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, HerdrTheme.pagePadding)
                    .padding(.vertical, 16)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("AGENT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(HerdrTheme.graphite, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(controller.isRunning ? "Stop" : "Close") {
                        Task {
                            await controller.close(model: model)
                            dismiss()
                        }
                    }
                    .disabled(controller.isSubmitting || controller.isPromoting)
                    .foregroundStyle(HerdrTheme.accent)
                    .accessibilityIdentifier("agent-close")
                }
            }
        }
        .presentationDragIndicator(.visible)
        // Swiping the sheet away mid-run would strand an agent on the machine,
        // and swiping away mid-promote would let `onDisappear` delete the run
        // out from under the promotion. The Stop button is the way out while it
        // is working; promotion is brief and finishes on its own.
        .interactiveDismissDisabled(
            controller.isRunning || controller.isSubmitting || controller.isPromoting
        )
        .herdrHaptic(trigger: hapticPulse)
        .task {
            // Focus first: the keyboard is a local state flip, and awaiting the
            // model catalog first left the field unfocused for as long as that
            // request took.
            isPromptFocused = true
            await loadAgentModels()
        }
        .onChange(of: controller.run?.status) { _, status in
            guard let status, status.isTerminal else { return }
            switch status {
            case .failed: hapticPulse.fire(.failed)
            case .cancelled: hapticPulse.fire(.stopped)
            default: hapticPulse.fire(.completed)
            }
        }
        .onDisappear {
            // A one-off run leaves no trace: closing the sheet deletes the run
            // record on the machine, promoted or not.
            Task { await controller.discard(model: model) }
        }
    }

    // MARK: Prompt

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Give the agent one job", systemImage: "sparkles")
                .font(.title3.bold())
                .foregroundStyle(HerdrTheme.text)
            Text("It runs on \(machineName) from your home folder and reports back here. Nothing joins your chat list unless you tap Continue as chat.")
                .font(.body)
                .foregroundStyle(HerdrTheme.mist)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var promptForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField(
                "Tell the agent what to do…",
                text: $prompt,
                axis: .vertical
            )
            .lineLimit(4...12)
            .font(.body)
            .foregroundStyle(HerdrTheme.text)
            .focused($isPromptFocused)
            .submitLabel(.send)
            .onSubmit(submit)
            .padding(13)
            .background(HerdrTheme.graphite)
            .overlay {
                RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                    .strokeBorder(isPromptFocused ? HerdrTheme.accent : HerdrTheme.surface, lineWidth: 1)
            }
            .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
            .accessibilityIdentifier("agent-prompt")

            modelRow

            Text("Runs from ~ with investigative CLI access and a current Herdr fleet summary.")
                .font(.caption)
                .foregroundStyle(HerdrTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: submit) {
                Label("Run Agent", systemImage: "arrow.up.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(HerdrTheme.accent)
            .disabled(!canSubmit)
            .accessibilityIdentifier("agent-submit")

            errorBanner
        }
        .padding(HerdrTheme.cardPadding)
        .background(HerdrTheme.elevated.opacity(0.42))
        .clipShape(.rect(cornerRadius: HerdrTheme.cardRadius))
    }

    /// A full-width row rather than the chat's `PiModelPickerChip`: that chip's
    /// label is 36pt tall, under the touch minimum, and it is shaped around a
    /// live pane's current model rather than a stored preference.
    private var modelRow: some View {
        Menu {
            Button {
                model.setAgentModel("")
            } label: {
                Label(
                    "Machine default",
                    systemImage: model.agentModel.isEmpty ? "checkmark.circle.fill" : "cpu"
                )
            }
            ForEach(catalogProviders, id: \.self) { provider in
                Section(provider) {
                    ForEach(modelsByProvider[provider] ?? []) { candidate in
                        Button {
                            model.setAgentModel(candidate.id)
                        } label: {
                            Label(
                                candidate.displayName,
                                systemImage: model.agentModel == candidate.id ? "checkmark.circle.fill" : "cpu"
                            )
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                Text("Model")
                    .foregroundStyle(HerdrTheme.mist)
                Spacer(minLength: 8)
                Text(agentModelLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .font(.subheadline)
            .foregroundStyle(HerdrTheme.accent)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .disabled(controller.isRunning)
        .accessibilityIdentifier("agent-model")
        .accessibilityLabel("Model: \(agentModelLabel)")
    }

    // MARK: Run

    @ViewBuilder
    private var runContent: some View {
        if let run = controller.run {
            VStack(alignment: .leading, spacing: 14) {
                Label(run.status.label, systemImage: statusSymbol(for: run.status))
                    .font(.headline.monospaced().bold())
                    .foregroundStyle(statusColor(for: run.status))
                    .accessibilityIdentifier("agent-status")

                VStack(alignment: .leading, spacing: 6) {
                    Text("YOU ASKED")
                        .font(.caption2.monospaced().weight(.bold))
                        .foregroundStyle(HerdrTheme.muted)
                    Text(run.prompt)
                        .font(.body)
                        .foregroundStyle(HerdrTheme.text)
                        .textSelection(.enabled)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HerdrTheme.elevated.opacity(0.55))
                .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))

                if !controller.steps.isEmpty {
                    HeadlessAgentStepsView(
                        steps: controller.steps,
                        isTruncated: run.stepsTruncated == true,
                        isLive: controller.isRunning
                    )
                }

                if controller.isRunning {
                    HStack(spacing: 10) {
                        ProgressView().tint(HerdrTheme.accent)
                        Text("working on \(machineName)…")
                            .font(.subheadline)
                            .foregroundStyle(HerdrTheme.mist)
                        Spacer(minLength: 8)
                        Button("Cancel", role: .destructive) {
                            Task { await controller.cancel(model: model) }
                        }
                        .buttonStyle(.bordered)
                        .tint(HerdrTheme.alert)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("agent-cancel")
                    }
                }

                if let response = run.response, !response.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("RESULT")
                                .font(.caption2.monospaced().weight(.bold))
                                .foregroundStyle(HerdrTheme.muted)
                            Spacer()
                            if let cost = run.costUSD {
                                Text(cost, format: .currency(code: "USD"))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(HerdrTheme.mist)
                            }
                        }
                        PiMarkdownMessageView(source: response, isStreaming: false)
                            .textSelection(.enabled)
                    }
                    .padding(HerdrTheme.cardPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(HerdrTheme.graphite)
                    .overlay {
                        RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                            .strokeBorder(HerdrTheme.surface, lineWidth: 1)
                    }
                    .clipShape(.rect(cornerRadius: HerdrTheme.cardRadius))
                    .accessibilityIdentifier("agent-response")
                }

                // `run.error` is the machine's own failure; `errorBanner` is the
                // client's. They can both be present and they mean different
                // things, so neither shadows the other.
                if let message = run.error, !message.isEmpty {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(HerdrTheme.alert)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                errorBanner
                terminalActions(for: run)
            }
        }
    }

    /// Stacked, not the Mac's single row: three controls do not fit across a
    /// phone, and each needs its own 44pt target.
    @ViewBuilder
    private func terminalActions(for run: HeadlessAgentRun) -> some View {
        if run.status.isTerminal {
            VStack(spacing: 10) {
                if controller.canPromote {
                    Menu {
                        Button("Quick chats") { promotionWorkspaceID = "" }
                        ForEach(promotionWorkspaces) { workspace in
                            Button(workspace.label) { promotionWorkspaceID = workspace.workspaceID }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "rectangle.3.group")
                            Text("Continue in")
                                .foregroundStyle(HerdrTheme.mist)
                            Spacer(minLength: 8)
                            Text(promotionTargetLabel)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                        }
                        .font(.subheadline)
                        .foregroundStyle(HerdrTheme.accent)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("agent-promotion-workspace")

                    Button {
                        Task {
                            let workspaceID = promotionWorkspaceID.isEmpty ? nil : promotionWorkspaceID
                            if let pane = await controller.promote(workspaceID: workspaceID, model: model) {
                                model.openPane(id: pane.id)
                                dismiss()
                            }
                        }
                    } label: {
                        Label("Continue as chat", systemImage: "bubble.left.and.bubble.right")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(HerdrTheme.accent)
                    .disabled(controller.isPromoting)
                    .accessibilityIdentifier("agent-promote")
                }

                Button {
                    Task {
                        await controller.discard(model: model)
                        prompt = ""
                        modelWarning = nil
                        promotionWorkspaceID = ""
                        isPromptFocused = true
                    }
                } label: {
                    Label("Run another", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(HerdrTheme.mist)
                .disabled(controller.isPromoting)
                .accessibilityIdentifier("agent-run-again")
            }
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = controller.errorMessage ?? modelWarning, !message.isEmpty {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(HerdrTheme.alert)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HerdrTheme.alert.opacity(0.1))
                .clipShape(.rect(cornerRadius: HerdrTheme.compactRadius))
                .accessibilityIdentifier("agent-error")
        }
    }

    // MARK: Actions

    private var canSubmit: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !controller.isRunning
    }

    private func submit() {
        guard canSubmit else { return }
        let resolution = AgentModelResolver.resolve(
            preference: model.agentModel,
            catalog: agentCatalog?.models ?? [],
            isCatalogAuthoritative: didLoadAgentCatalog
        )
        modelWarning = resolution.preferenceIsUnavailable
            ? "That model isn't on \(machineName) — running with the machine default."
            : nil
        isPromptFocused = false
        hapticPulse.fire(.promptSent)
        Task {
            await controller.submit(
                prompt: prompt,
                machineID: machineID,
                agentModel: resolution.modelID,
                thinkingLevel: HeadlessAgentRunDefaults.thinkingLevel.rawValue,
                model: model
            )
        }
    }

    private func loadAgentModels() async {
        do {
            agentCatalog = try await model.fetchAgentModels(machineID: machineID)
            didLoadAgentCatalog = true
        } catch {
            // A failed catalog refresh must not invalidate a stored preference.
            // The resolver sends it unverified instead of silently dropping it.
        }
    }

    // MARK: Derived

    private var machineName: String {
        model.machines.first(where: { $0.id == machineID })?.name ?? machineID
    }

    private var agentModelLabel: String {
        let selection = model.agentModel
        if !selection.isEmpty {
            return agentCatalog?.models.first(where: { $0.id == selection })?.displayName ?? selection
        }
        return agentCatalog?.defaultModel?.displayName ?? "machine default"
    }

    private var modelsByProvider: [String: [PiAvailableModel]] {
        Dictionary(grouping: agentCatalog?.models ?? [], by: \.provider)
    }

    private var catalogProviders: [String] {
        modelsByProvider.keys.sorted()
    }

    private var promotionWorkspaces: [HerdrWorkspace] {
        model.workspaces
            .filter { $0.machineID == machineID }
            .sorted { $0.number < $1.number }
    }

    private var promotionTargetLabel: String {
        guard !promotionWorkspaceID.isEmpty else { return "Quick chats" }
        return promotionWorkspaces.first(where: { $0.workspaceID == promotionWorkspaceID })?.label
            ?? "Quick chats"
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
