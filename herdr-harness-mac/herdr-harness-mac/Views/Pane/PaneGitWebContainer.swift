import SwiftUI
import WebKit

struct PaneGitWebContainer: NSViewRepresentable {
    let document: PaneGitWebDocument
    @Binding var phase: PaneGitWebLoadPhase

    func makeCoordinator() -> PaneGitNavigationDelegate {
        PaneGitNavigationDelegate(phase: $phase)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.websiteDataStore = .nonPersistent()
        webConfiguration.defaultWebpagePreferences.allowsContentJavaScript = true
        webConfiguration.userContentController.addUserScript(Self.userScript(for: document))

        let webView = WKWebView(frame: .zero, configuration: webConfiguration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.underPageBackgroundColor = NSColor(HerdrTheme.ink)
        context.coordinator.load(document, in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.loadedDocument != document {
            webView.configuration.userContentController.removeAllUserScripts()
            webView.configuration.userContentController.addUserScript(Self.userScript(for: document))
        }
        context.coordinator.load(document, in: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: PaneGitNavigationDelegate) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeAllUserScripts()
    }

    private static func userScript(for document: PaneGitWebDocument) -> WKUserScript {
        WKUserScript(
            source: document.bootstrapScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }
}
