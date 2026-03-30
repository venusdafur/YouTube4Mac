import SwiftUI
import WebKit

private enum AppConfig {
    static let homeURL = URL(string: "https://www.youtube.com")!
    static let adBlockerIdentifier = "YouTube4MacAdBlock"
}

private enum AppIconLoader {
    static func apply() {
        guard
            let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
            let iconImage = NSImage(contentsOf: iconURL)
        else {
            return
        }

        NSApplication.shared.applicationIconImage = iconImage
    }
}

enum ThemeMode: String, CaseIterable, Identifiable {
    case dark
    case light

    var id: Self { self }

    var label: String {
        switch self {
        case .dark:
            "Dark"
        case .light:
            "Light"
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .dark:
            .dark
        case .light:
            .light
        }
    }

    var cssScheme: String {
        switch self {
        case .dark:
            "dark"
        case .light:
            "light"
        }
    }
}

struct WebView: NSViewRepresentable {
    let themeMode: ThemeMode

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
                    if (!document.getElementById('youtube4mac-theme')) {
                        const style = document.createElement('style');
                        style.id = 'youtube4mac-theme';
                        document.documentElement.appendChild(style);
                    }
                })();
                """,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        controller.addUserScript(
            WKUserScript(
                source: """
                (() => {
                    const selectors = [
                        'ytd-display-ad-renderer',
                        'ytd-ad-slot-renderer',
                        'ytd-video-masthead-ad-v3-renderer',
                        'ytd-in-feed-ad-layout-renderer',
                        'ytm-promoted-sparkles-web-renderer',
                        '.ytd-promoted-sparkles-web-renderer',
                        '.ytp-ad-overlay-container',
                        '.ytp-ad-message-container',
                        '[layout*="display-ad-renderer"]',
                        '[class*="ytd-display-ad-renderer"]'
                    ];

                    const ensureStyle = () => {
                        if (document.getElementById('youtube4mac-adblock-style')) return;
                        const style = document.createElement('style');
                        style.id = 'youtube4mac-adblock-style';
                        style.textContent = `${selectors.join(',')} { display: none !important; }`;
                        document.documentElement.appendChild(style);
                    };

                    const hideAds = () => {
                        ensureStyle();
                        selectors.forEach((selector) => {
                            document.querySelectorAll(selector).forEach((node) => node.remove());
                        });

                        document.querySelector('.ytp-ad-skip-button, .ytp-skip-ad-button, .ytp-ad-skip-button-modern')?.click();

                        const video = document.querySelector('video');
                        if (video && document.querySelector('.ad-showing')) {
                            const duration = Number.isFinite(video.duration) ? video.duration : 0;
                            video.currentTime = duration > 0 ? duration : 9999;
                        }
                    };

                    hideAds();
                    new MutationObserver(hideAds).observe(document.documentElement, {
                        childList: true,
                        subtree: true
                    });
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
        context.coordinator.installContentBlocker(into: controller, for: webView)
        applyTheme(themeMode, to: webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        applyTheme(themeMode, to: nsView)
        context.coordinator.loadIfNeeded(nsView)
    }

    private func applyTheme(_ themeMode: ThemeMode, to webView: WKWebView) {
        webView.appearance = themeMode == .dark ? NSAppearance(named: .darkAqua) : NSAppearance(named: .aqua)
        webView.evaluateJavaScript(
            """
            (() => {
                const style = document.getElementById('youtube4mac-theme');
                if (!style) return;
                style.textContent = `
                    :root {
                        color-scheme: \(themeMode.cssScheme);
                    }
                `;
            })();
            """
        )
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var didInstallBlocker = false
        private var didStartInitialLoad = false

        func installContentBlocker(into controller: WKUserContentController, for webView: WKWebView) {
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: AppConfig.adBlockerIdentifier,
                encodedContentRuleList: Self.contentBlockingRules
            ) { [weak self] ruleList, _ in
                DispatchQueue.main.async {
                    if let ruleList {
                        controller.add(ruleList)
                    }

                    self?.didInstallBlocker = true
                    self?.loadIfNeeded(webView)
                }
            }
        }

        func loadIfNeeded(_ webView: WKWebView) {
            guard didInstallBlocker, !didStartInitialLoad else { return }
            didStartInitialLoad = true
            webView.load(URLRequest(url: AppConfig.homeURL))
        }

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

        private static let contentBlockingRules = """
        [
          {
            "trigger": {
              "url-filter": "https?://([A-Za-z0-9.-]+\\\\.)?(doubleclick\\\\.net|googlesyndication\\\\.com|googleadservices\\\\.com|googletagmanager\\\\.com)/.*"
            },
            "action": {
              "type": "block"
            }
          },
          {
            "trigger": {
              "url-filter": "https?://([A-Za-z0-9.-]+\\\\.)?youtube\\\\.com/api/stats/ads.*"
            },
            "action": {
              "type": "block"
            }
          },
          {
            "trigger": {
              "url-filter": "https?://([A-Za-z0-9.-]+\\\\.)?youtubei\\\\.googleapis\\\\.com/.*ad.*"
            },
            "action": {
              "type": "block"
            }
          },
          {
            "trigger": {
              "url-filter": ".*",
              "if-domain": ["www.youtube.com", "youtube.com", "m.youtube.com"]
            },
            "action": {
              "type": "css-display-none",
              "selector": "ytd-display-ad-renderer, ytd-ad-slot-renderer, ytd-video-masthead-ad-v3-renderer, ytd-in-feed-ad-layout-renderer, ytm-promoted-sparkles-web-renderer, .ytd-promoted-sparkles-web-renderer, .ytp-ad-overlay-container, .ytp-ad-message-container"
            }
          }
        ]
        """
    }
}

struct ContentView: View {
    let themeMode: ThemeMode

    var body: some View {
        WebView(themeMode: themeMode)
            .ignoresSafeArea()
            .background(themeMode == .dark ? .black : .white)
            .preferredColorScheme(themeMode.colorScheme)
    }
}

@main
struct YouTube4MacApp: App {
    @AppStorage("themeMode") private var themeModeRawValue = ThemeMode.dark.rawValue

    init() {
        AppIconLoader.apply()
    }

    private var themeMode: ThemeMode {
        ThemeMode(rawValue: themeModeRawValue) ?? .dark
    }

    var body: some Scene {
        WindowGroup {
            ContentView(themeMode: themeMode)
                .frame(minWidth: 980, minHeight: 680)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandMenu("Appearance") {
                Picker("Theme", selection: $themeModeRawValue) {
                    ForEach(ThemeMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
            }
        }
    }
}
