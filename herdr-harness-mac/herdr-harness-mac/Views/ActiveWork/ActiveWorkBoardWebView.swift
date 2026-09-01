import AppKit
import SwiftUI

struct ActiveWorkBoardWebView: View {
    let configuration: ServerConfiguration
    let openPane: (String, String?) -> Void
    let openExternal: (URL) -> Void
    let copyText: (String) -> Void
    let popOut: (() -> Void)?

    @State private var phase: PaneGitWebLoadPhase = .loading
    @State private var reloadID = 0
    @State private var localToastMessage: String?

    var body: some View {
        ZStack {
            ActiveWorkBoardContainer(
                document: ActiveWorkBoardDocument(configuration: configuration),
                phase: $phase,
                openPane: openPane,
                openExternal: openExternal,
                copyText: copyText,
                popOut: popOut ?? { localToastMessage = "Already in its own window" }
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

            if let localToastMessage {
                VStack {
                    ToastView(message: localToastMessage) { self.localToastMessage = nil }
                        .padding(.top, 8)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: localToastMessage)
        .background(Color.black)
        .accessibilityIdentifier("active-work-board-web")
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Loading Active Work board…")
                .herdrFont(.caption, monospaced: true, weight: .medium)
                .foregroundStyle(HerdrTheme.mist)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HerdrTheme.ink.opacity(0.94))
        .accessibilityElement(children: .combine)
    }

    private func failureView(message: String) -> some View {
        ContentUnavailableView {
            Label("Active Work board unavailable", systemImage: "exclamationmark.triangle")
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

struct ActiveWorkBoardEmptyStateView: View {
    var body: some View {
        ZStack {
            HerdrBackground()
            ContentUnavailableView(
                "Connect a machine to see the board",
                systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                description: Text("Active Work needs a live connection to a machine before its board can load.")
            )
        }
    }
}

struct ActiveWorkBoardWindowRoot: View {
    @Bindable var model: HerdrAppModel
    @Bindable var shell: HerdrShellState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let configuration = model.activeServerConfiguration {
            ActiveWorkBoardWebView(
                configuration: configuration,
                openPane: { paneID, machineID in
                    NSApp.activate()
                    openWindow(id: HerdrWindowID.main)
                    shell.openPane(rawPaneID: paneID, machineID: machineID, model: model)
                },
                openExternal: { url in
                    Task {
                        do {
                            try await ActiveWorkLinkOpener.open(url)
                        } catch {
                            model.toastMessage = error.localizedDescription
                        }
                    }
                },
                copyText: { model.copyToPasteboard($0) },
                popOut: nil
            )
        } else {
            ActiveWorkBoardEmptyStateView()
        }
    }
}
