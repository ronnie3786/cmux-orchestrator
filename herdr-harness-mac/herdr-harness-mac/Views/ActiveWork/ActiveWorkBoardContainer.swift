import SwiftUI
import WebKit

struct ActiveWorkBoardContainer: NSViewRepresentable {
    let document: ActiveWorkBoardDocument
    @Binding var phase: PaneGitWebLoadPhase
    let openPane: (String, String?) -> Void
    let openExternal: (URL) -> Void
    let copyText: (String) -> Void
    let popOut: () -> Void

    func makeCoordinator() -> ActiveWorkBoardNavigationDelegate {
        ActiveWorkBoardNavigationDelegate(
            phase: $phase,
            openPane: openPane,
            openExternal: openExternal,
            copyText: copyText,
            popOut: popOut
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.websiteDataStore = .nonPersistent()
        webConfiguration.defaultWebpagePreferences.allowsContentJavaScript = true
        webConfiguration.userContentController.addUserScript(Self.userScript(for: document))
        webConfiguration.userContentController.add(context.coordinator, name: "herdrBoard")

        let webView = WKWebView(frame: .zero, configuration: webConfiguration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.underPageBackgroundColor = .black
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

    static func dismantleNSView(_ webView: WKWebView, coordinator: ActiveWorkBoardNavigationDelegate) {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "herdrBoard")
        webView.configuration.userContentController.removeAllUserScripts()
        webView.navigationDelegate = nil
    }

    private static func userScript(for document: ActiveWorkBoardDocument) -> WKUserScript {
        WKUserScript(
            source: document.bootstrapScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }
}

enum ActiveWorkBoardMessage: Equatable {
    case openPane(paneId: String, machineId: String?)
    case openExternal(url: String)
    case copy(text: String)
    case popout

    static func parse(_ body: [String: Any]) -> ActiveWorkBoardMessage? {
        guard let type = body["type"] as? String else { return nil }
        switch type {
        case "openPane":
            guard let paneId = body["paneId"] as? String else { return nil }
            return .openPane(paneId: paneId, machineId: body["machineId"] as? String)
        case "openExternal":
            guard let url = body["url"] as? String else { return nil }
            return .openExternal(url: url)
        case "copy":
            guard let text = body["text"] as? String else { return nil }
            return .copy(text: text)
        case "popout":
            return .popout
        default:
            return nil
        }
    }
}
