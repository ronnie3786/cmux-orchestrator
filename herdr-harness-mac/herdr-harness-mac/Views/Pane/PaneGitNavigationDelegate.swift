import SwiftUI
import WebKit

@MainActor
final class PaneGitNavigationDelegate: NSObject, WKNavigationDelegate {
    private var phase: Binding<PaneGitWebLoadPhase>
    private(set) var loadedDocument: PaneGitWebDocument?

    init(phase: Binding<PaneGitWebLoadPhase>) {
        self.phase = phase
    }

    func load(_ document: PaneGitWebDocument, in webView: WKWebView) {
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
        guard let url = navigationAction.request.url,
              loadedDocument?.allowedOrigin.contains(url) == true
        else { return .cancel }
        return .allow
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
        guard (error as? URLError)?.code != .cancelled else { return }
        phase.wrappedValue = .failed(error.localizedDescription)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: any Error
    ) {
        guard (error as? URLError)?.code != .cancelled else { return }
        phase.wrappedValue = .failed(error.localizedDescription)
    }
}
