import SwiftUI
import WebKit

/// Console message from browser JavaScript
struct BrowserConsoleMessage {
    enum Level: String {
        case log, warn, error, info, debug
    }
    let level: Level
    let message: String
    let timestamp: Date
}

/// WebView with reload capability via binding
struct ReloadableWebView: NSViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var reloadTrigger: Int
    var onError: ((String) -> Void)?
    var onConsoleMessage: ((BrowserConsoleMessage) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()

        // Add script message handler for console interception
        let contentController = config.userContentController
        contentController.add(context.coordinator, name: "consoleLog")

        // Inject JavaScript to intercept console methods
        let consoleScript = WKUserScript(
            source: Self.consoleInterceptorScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        contentController.addUserScript(consoleScript)

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

    /// JavaScript that intercepts console.log/warn/error/info/debug
    private static let consoleInterceptorScript = """
    (function() {
        const originalConsole = {
            log: console.log.bind(console),
            warn: console.warn.bind(console),
            error: console.error.bind(console),
            info: console.info.bind(console),
            debug: console.debug.bind(console)
        };

        function formatArgs(args) {
            return Array.from(args).map(arg => {
                if (arg === null) return 'null';
                if (arg === undefined) return 'undefined';
                if (typeof arg === 'object') {
                    try {
                        return JSON.stringify(arg, null, 2);
                    } catch (e) {
                        return String(arg);
                    }
                }
                return String(arg);
            }).join(' ');
        }

        function interceptConsole(level) {
            return function() {
                const message = formatArgs(arguments);
                try {
                    window.webkit.messageHandlers.consoleLog.postMessage({
                        level: level,
                        message: message
                    });
                } catch (e) {}
                originalConsole[level].apply(console, arguments);
            };
        }

        console.log = interceptConsole('log');
        console.warn = interceptConsole('warn');
        console.error = interceptConsole('error');
        console.info = interceptConsole('info');
        console.debug = interceptConsole('debug');

        // Also capture uncaught errors
        window.addEventListener('error', function(event) {
            try {
                window.webkit.messageHandlers.consoleLog.postMessage({
                    level: 'error',
                    message: event.message + ' at ' + event.filename + ':' + event.lineno + ':' + event.colno
                });
            } catch (e) {}
        });

        // Capture unhandled promise rejections
        window.addEventListener('unhandledrejection', function(event) {
            try {
                window.webkit.messageHandlers.consoleLog.postMessage({
                    level: 'error',
                    message: 'Unhandled Promise Rejection: ' + String(event.reason)
                });
            } catch (e) {}
        });
    })();
    """

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: ReloadableWebView
        var lastReloadTrigger: Int = 0
        weak var webView: WKWebView?

        init(_ parent: ReloadableWebView) {
            self.parent = parent
            self.lastReloadTrigger = parent.reloadTrigger
        }

        // MARK: - WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "consoleLog",
                  let body = message.body as? [String: Any],
                  let levelStr = body["level"] as? String,
                  let messageStr = body["message"] as? String
            else { return }

            let consoleMessage = BrowserConsoleMessage(
                level: BrowserConsoleMessage.Level(rawValue: levelStr) ?? .log,
                message: messageStr,
                timestamp: Date()
            )

            DispatchQueue.main.async {
                self.parent.onConsoleMessage?(consoleMessage)
            }
        }

        // MARK: - WKNavigationDelegate

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
