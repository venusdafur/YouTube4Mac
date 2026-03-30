import SwiftUI
import WebKit

private enum AppConfig {
    static let homeURL = URL(string: "https://www.youtube.com")!
}

struct WebView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let controller = WKUserContentController()
        controller.addUserScript(
            WKUserScript(
                source: """
                (() => {
                    const style = document.createElement('style');
                    style.textContent = `
                        :root {
                            color-scheme: dark;
                        }
                    `;
                    document.documentElement.appendChild(style);
                })();
                """,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.load(URLRequest(url: AppConfig.homeURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }
    }
}

struct ContentView: View {
    var body: some View {
        WebView()
            .ignoresSafeArea()
            .background(.black)
            .preferredColorScheme(.dark)
    }
}

@main
struct YouTube4MacApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 980, minHeight: 680)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1280, height: 820)
    }
}
