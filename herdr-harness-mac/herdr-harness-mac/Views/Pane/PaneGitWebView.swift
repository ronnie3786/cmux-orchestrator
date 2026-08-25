import SwiftUI

struct PaneGitWebView: View {
    let configuration: ServerConfiguration
    let workspaceID: String
    let paneID: String

    @State private var phase: PaneGitWebLoadPhase = .loading
    @State private var reloadID = 0

    var body: some View {
        ZStack {
            PaneGitWebContainer(
                document: PaneGitWebDocument(
                    configuration: configuration,
                    workspaceID: workspaceID,
                    paneID: paneID
                ),
                phase: $phase
            )
            .id(reloadID)

            switch phase {
            case .loading:
                loadingView
            case .ready:
                EmptyView()
            case let .failed(message):
                failureView(message: message)
            }
        }
        .background(HerdrTheme.ink)
        .accessibilityIdentifier("pane-git-web")
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Loading Git changes…")
                .herdrFont(.caption, monospaced: true, weight: .medium)
                .foregroundStyle(HerdrTheme.mist)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HerdrTheme.ink.opacity(0.94))
        .accessibilityElement(children: .combine)
    }

    private func failureView(message: String) -> some View {
        ContentUnavailableView {
            Label("Git view unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", systemImage: "arrow.clockwise") {
                phase = .loading
                reloadID &+= 1
            }
            .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(HerdrTheme.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HerdrTheme.ink)
    }
}
