import SwiftUI
import WebKit

@MainActor
final class ActiveWorkBoardNavigationDelegate: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private var phase: Binding<PaneGitWebLoadPhase>
    private(set) var loadedDocument: ActiveWorkBoardDocument?
    private let openPane: (String, String?) -> Void
    private let openExternal: (URL) -> Void
    private let copyText: (String) -> Void
    private let popOut: () -> Void
    private let spawnReview: (ActiveWorkSpawnReviewPayload) -> Void

    init(
        phase: Binding<PaneGitWebLoadPhase>,
        openPane: @escaping (String, String?) -> Void,
        openExternal: @escaping (URL) -> Void,
        copyText: @escaping (String) -> Void,
        popOut: @escaping () -> Void,
        spawnReview: @escaping (ActiveWorkSpawnReviewPayload) -> Void
    ) {
        self.phase = phase
        self.openPane = openPane
        self.openExternal = openExternal
        self.copyText = copyText
        self.popOut = popOut
        self.spawnReview = spawnReview
    }

    func load(_ document: ActiveWorkBoardDocument, in webView: WKWebView) {
        guard loadedDocument != document else { return }
        loadedDocument = document
        phase.wrappedValue = .loading
        webView.load(
            URLRequest(
                url: document.url,
                cachePolicy: .reloadRevalidatingCacheData,
                timeoutInterval: 30
            )
        )
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if loadedDocument?.allowedOrigin.contains(url) == true { return .allow }
        if navigationAction.navigationType == .linkActivated { openExternal(url) }
        return .cancel
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        phase.wrappedValue = .loading
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        phase.wrappedValue = .ready
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: any Error
    ) {
        guard !HerdrCancellation.isCancellation(error) else { return }
        phase.wrappedValue = .failed(error.localizedDescription)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: any Error
    ) {
        guard !HerdrCancellation.isCancellation(error) else { return }
        phase.wrappedValue = .failed(error.localizedDescription)
    }

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        Task { @MainActor [weak self] in
            guard let body = message.body as? [String: Any],
                  let parsed = ActiveWorkBoardMessage.parse(body) else { return }
            self?.handle(parsed)
        }
    }

    private func handle(_ message: ActiveWorkBoardMessage) {
        switch message {
        case let .openPane(paneId, machineId):
            openPane(paneId, machineId)
        case let .openExternal(urlString):
            guard let url = URL(string: urlString) else { return }
            openExternal(url)
        case let .copy(text):
            copyText(text)
        case .popout:
            popOut()
        case let .spawnReview(payload):
            spawnReview(payload)
        }
    }
}
