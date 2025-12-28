import SwiftUI
import WebKit

/// WebView with reload capability via binding
struct ReloadableWebView: NSViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var reloadTrigger: Int
    var onError: ((String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        context.coordinator.webView = webView

        let request = URLRequest(url: url)
        webView.load(request)

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Reload when trigger changes
        if context.coordinator.lastReloadTrigger != reloadTrigger {
            context.coordinator.lastReloadTrigger = reloadTrigger
            webView.reload()
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: ReloadableWebView
        var lastReloadTrigger: Int = 0
        weak var webView: WKWebView?

        init(_ parent: ReloadableWebView) {
            self.parent = parent
            self.lastReloadTrigger = parent.reloadTrigger
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = true
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.onError?(error.localizedDescription)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.onError?(error.localizedDescription)
            }
        }
    }
}
