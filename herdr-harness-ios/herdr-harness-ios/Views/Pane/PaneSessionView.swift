import SwiftUI

struct PaneSessionView: View {
    @Bindable var model: HerdrAppModel
    let pane: HerdrPane
    @State private var output = "Connecting to terminal…"
    @State private var outputRevision = 0
    @State private var terminalGrid = TerminalGrid(columns: 100, rows: 32)
    @State private var hasLiveFrame = false
    @State private var isFollowing = true
    @State private var outputError: String?

    var body: some View {
        ZStack {
            HerdrBackground()

            VStack(spacing: 0) {
                PaneSessionHeader(model: model, pane: currentPane)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                PaneTerminalView(
                    pane: currentPane,
                    output: output,
                    attributedOutput: hasLiveFrame ? terminalGrid.attributedText : nil,
                    revision: outputRevision,
                    dimensions: hasLiveFrame ? "\(terminalGrid.columns)×\(terminalGrid.rows)" : nil,
                    isFollowing: $isFollowing
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                PromptComposerView(model: model, pane: currentPane)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
            }
        }
        .navigationTitle(currentPane.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                PaneActionsMenu(model: model, pane: currentPane)
            }
        }
        .task(id: pane.id) {
            await followOutput()
        }
        .overlay(alignment: .top) {
            if let outputError {
                Text(outputError)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(HerdrTheme.alert, in: Capsule())
                    .padding(.top, 8)
                    .accessibilityLabel("Terminal error: \(outputError)")
            }
        }
    }

    private var currentPane: HerdrPane {
        model.pane(id: pane.id) ?? pane
    }

    private func followOutput() async {
        await refreshOutput()
        if model.isDemoMode { return }

        while !Task.isCancelled {
            do {
                guard let frames = await model.terminalFrames(for: currentPane) else {
                    await refreshOutput()
                    try await Task.sleep(for: .milliseconds(650))
                    continue
                }
                for try await frame in frames {
                    try Task.checkCancellation()
                    var updatedGrid = terminalGrid
                    guard updatedGrid.apply(frame) else { throw APIError.invalidResponse }
                    terminalGrid = updatedGrid
                    hasLiveFrame = true
                    outputRevision = frame.sequence
                    outputError = nil
                }
                throw APIError.streamEnded
            } catch is CancellationError {
                return
            } catch {
                // The low-cost text endpoint is also the graceful fallback
                // when the live observer is temporarily unavailable.
                if !hasLiveFrame { await refreshOutput() }
            }

            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
        }
    }

    private func refreshOutput() async {
        do {
            let response = try await model.fetchOutput(for: currentPane)
            try Task.checkCancellation()
            if !hasLiveFrame, response.revision >= outputRevision || output == "Connecting to terminal…" {
                output = response.text.isEmpty ? "No terminal output yet." : response.text
                outputRevision = response.revision
            }
            outputError = nil
        } catch is CancellationError {
            return
        } catch {
            outputError = error.localizedDescription
        }
    }
}
