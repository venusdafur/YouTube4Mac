import Foundation
import SwiftUI
import WebKit

private enum AppConfig {
    static let homeURL = URL(string: "https://www.youtube.com")!
    static let adBlockerIdentifier = "YouTube4MacAdBlock"
    static let githubURL = URL(string: "https://github.com/venusdafur/YouTube4Mac")!
    static let returnYouTubeDislikeAPI = URL(string: "https://returnyoutubedislikeapi.com/votes")!
    static let returnYouTubeDislikeMessageHandler = "youtube4macVideoChanged"
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

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case cookies

    var id: Self { self }

    var title: String {
        switch self {
        case .general:
            "General"
        case .cookies:
            "Cookies"
        }
    }
}

private enum CookieImporter {
    enum Outcome {
        case success(Int)
        case failure(String)
    }

    private static let reservedAttributes: Set<String> = [
        "path", "domain", "expires", "max-age", "secure", "httponly", "samesite"
    ]

    static func importCookies(
        from rawText: String,
        defaultDomain: String,
        completion: @escaping (Outcome) -> Void
    ) {
        let cookies = parseCookies(from: rawText, defaultDomain: defaultDomain)
        guard !cookies.isEmpty else {
            completion(.failure("No valid cookies were found to import."))
            return
        }

        let cookieStore = WKWebsiteDataStore.default().httpCookieStore
        let dispatchGroup = DispatchGroup()

        for cookie in cookies {
            dispatchGroup.enter()
            HTTPCookieStorage.shared.setCookie(cookie)
            cookieStore.setCookie(cookie) {
                dispatchGroup.leave()
            }
        }

        dispatchGroup.notify(queue: .main) {
            completion(.success(cookies.count))
        }
    }

    private static func parseCookies(from rawText: String, defaultDomain: String) -> [HTTPCookie] {
        let normalizedDomain = normalizeDomain(defaultDomain)
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if trimmed.contains("\t") {
            return parseNetscapeCookies(from: trimmed)
        }

        return parseSimpleCookies(from: trimmed, defaultDomain: normalizedDomain)
    }

    private static func parseNetscapeCookies(from rawText: String) -> [HTTPCookie] {
        rawText
            .components(separatedBy: .newlines)
            .compactMap { line -> HTTPCookie? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

                let fields = trimmed.components(separatedBy: "\t")
                guard fields.count >= 7 else { return nil }

                let domain = normalizeDomain(fields[0])
                let path = fields[2].isEmpty ? "/" : fields[2]
                let isSecure = fields[3].uppercased() == "TRUE"
                let expiration = TimeInterval(fields[4]).flatMap(Date.init(timeIntervalSince1970:))
                let name = fields[5]
                let value = fields[6]

                return makeCookie(
                    name: name,
                    value: value,
                    domain: domain,
                    path: path,
                    isSecure: isSecure,
                    expirationDate: expiration
                )
            }
    }

    private static func parseSimpleCookies(from rawText: String, defaultDomain: String) -> [HTTPCookie] {
        let segments = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: ";")
            .components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return segments.compactMap { segment in
            guard let separatorIndex = segment.firstIndex(of: "=") else { return nil }
            let name = String(segment[..<separatorIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(segment[segment.index(after: separatorIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)

            guard !name.isEmpty, !reservedAttributes.contains(name.lowercased()) else { return nil }

            return makeCookie(
                name: name,
                value: value,
                domain: defaultDomain,
                path: "/",
                isSecure: true,
                expirationDate: Date(timeIntervalSinceNow: 60 * 60 * 24 * 365)
            )
        }
    }

    private static func makeCookie(
        name: String,
        value: String,
        domain: String,
        path: String,
        isSecure: Bool,
        expirationDate: Date?
    ) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
        ]

        if isSecure {
            properties[.secure] = "TRUE"
        }

        if let expirationDate {
            properties[.expires] = expirationDate
        }

        return HTTPCookie(properties: properties)
    }

    private static func normalizeDomain(_ domain: String) -> String {
        let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ".youtube.com" }
        if trimmed.hasPrefix(".") { return trimmed }
        return ".\(trimmed)"
    }
}

struct WebView: NSViewRepresentable {
    let isAdBlockEnabled: Bool
    let isReturnYouTubeDislikeEnabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let controller = WKUserContentController()
        controller.add(context.coordinator, name: AppConfig.returnYouTubeDislikeMessageHandler)
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
                            let style = document.getElementById('youtube4mac-adblock-style');
                            if (!style) {
                                style = document.createElement('style');
                                style.id = 'youtube4mac-adblock-style';
                                document.documentElement.appendChild(style);
                            }
                            style.textContent = window.youtube4macAdBlockEnabled
                                ? `${selectors.join(',')} { display: none !important; }`
                                : '';
                        };

                        const hideAds = () => {
                            ensureStyle();
                            if (!window.youtube4macAdBlockEnabled) return;

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

                        window.youtube4macApplyAdBlock = () => {
                            hideAds();
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
        controller.addUserScript(
            WKUserScript(
                source: """
                    (() => {
                        const formatDislikes = (count) => {
                            try {
                                return new Intl.NumberFormat(undefined, { notation: 'compact', maximumFractionDigits: 1 }).format(count);
                            } catch {
                                return String(count);
                            }
                        };

                        const getVideoId = () => {
                            const url = new URL(window.location.href);
                            if (url.pathname === '/watch') {
                                return url.searchParams.get('v');
                            }
                            if (url.pathname.startsWith('/shorts/')) {
                                return url.pathname.split('/')[2] || null;
                            }
                            return null;
                        };

                        const notifyNative = () => {
                            const videoId = getVideoId();
                            window.webkit?.messageHandlers?.\(AppConfig.returnYouTubeDislikeMessageHandler)?.postMessage({
                                videoId
                            });
                        };

                        const findDislikeButton = () => {
                            const segmentedDislike = document.querySelector('#segmented-dislike-button button');
                            if (segmentedDislike) {
                                return segmentedDislike;
                            }

                            const segmentedRenderer = document.querySelector('ytd-segmented-like-dislike-button-renderer');
                            if (segmentedRenderer) {
                                const buttons = segmentedRenderer.querySelectorAll('button');
                                if (buttons.length >= 2) {
                                    return buttons[1];
                                }
                            }

                            const directMatch = document.querySelector('ytd-toggle-button-renderer button');
                            if (directMatch && ((directMatch.getAttribute('aria-label') || '').toLowerCase().includes('dislike'))) {
                                return directMatch;
                            }

                            const buttons = Array.from(document.querySelectorAll('ytd-segmented-like-dislike-button-renderer button, ytd-menu-renderer ytd-toggle-button-renderer button'));
                            return buttons.find((button) => {
                                const label = (button.getAttribute('aria-label') || '').toLowerCase();
                                return label.includes('dislike');
                            }) || null;
                        };

                        const ensureDislikeBadge = () => {
                            let badge = document.querySelector('.youtube4mac-ryd-badge');
                            if (badge) return badge;

                            const host =
                                document.querySelector('#above-the-fold #title') ||
                                document.querySelector('ytd-watch-metadata #title') ||
                                document.querySelector('ytd-watch-metadata') ||
                                document.querySelector('#above-the-fold');

                            if (!host) return null;

                            badge = document.createElement('div');
                            badge.className = 'youtube4mac-ryd-badge';
                            badge.style.display = 'inline-flex';
                            badge.style.alignItems = 'center';
                            badge.style.justifyContent = 'flex-start';
                            badge.style.width = 'fit-content';
                            badge.style.minHeight = '32px';
                            badge.style.padding = '0 12px';
                            badge.style.marginTop = '10px';
                            badge.style.borderRadius = '16px';
                            badge.style.background = 'rgba(255,255,255,0.08)';
                            badge.style.color = 'var(--yt-spec-text-primary, #f1f1f1)';
                            badge.style.fontSize = '1.25rem';
                            badge.style.fontWeight = '600';
                            badge.style.lineHeight = '1';
                            badge.style.whiteSpace = 'nowrap';
                            badge.textContent = '';

                            host.appendChild(badge);
                            return badge;
                        };

                        const applyDislikeCount = () => {
                            const enabled = !!window.youtube4macReturnYouTubeDislikeEnabled;
                            const button = findDislikeButton();
                            const badge = ensureDislikeBadge();

                            if (!enabled) {
                                if (badge) {
                                    badge.textContent = '';
                                    badge.style.display = 'none';
                                }
                                if (button) {
                                    delete button.dataset.youtube4macRydVideoId;
                                }
                                return;
                            }

                            if (!button || !badge) return;
                            notifyNative();
                        };

                        window.youtube4macSetDislikeCount = (videoId, dislikes) => {
                            const button = findDislikeButton();
                            const badge = ensureDislikeBadge();
                            if (!button || !badge) return;

                            if (!window.youtube4macReturnYouTubeDislikeEnabled) {
                                badge.textContent = '';
                                badge.style.display = 'none';
                                delete button.dataset.youtube4macRydVideoId;
                                return;
                            }

                            if (!videoId || typeof dislikes !== 'number') {
                                badge.textContent = '';
                                badge.style.display = 'none';
                                delete button.dataset.youtube4macRydVideoId;
                                return;
                            }

                            badge.textContent = `Dislikes: ${formatDislikes(dislikes)}`;
                            badge.style.display = 'inline-flex';
                            button.setAttribute('aria-label', `Dislike ${formatDislikes(dislikes)}`);
                            button.dataset.youtube4macRydVideoId = videoId;
                        };

                        window.youtube4macApplyDislikes = applyDislikeCount;
                        applyDislikeCount();

                        if (!window.youtube4macDislikeObserver) {
                            window.youtube4macDislikeObserver = new MutationObserver(() => {
                                window.youtube4macApplyDislikes?.();
                            });
                            window.youtube4macDislikeObserver.observe(document.documentElement, {
                                childList: true,
                                subtree: true
                            });
                            window.addEventListener('yt-navigate-finish', () => {
                                const button = findDislikeButton();
                                if (button) {
                                    delete button.dataset.youtube4macRydVideoId;
                                }
                                notifyNative();
                            });
                        }
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
        context.coordinator.installContentBlocker(into: controller, for: webView, isEnabled: isAdBlockEnabled)
        applyPreferences(
            isAdBlockEnabled: isAdBlockEnabled,
            isReturnYouTubeDislikeEnabled: isReturnYouTubeDislikeEnabled,
            to: webView
        )
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.updateAdBlockState(isAdBlockEnabled, for: nsView)
        applyPreferences(
            isAdBlockEnabled: isAdBlockEnabled,
            isReturnYouTubeDislikeEnabled: isReturnYouTubeDislikeEnabled,
            to: nsView
        )
        context.coordinator.loadIfNeeded(nsView)
    }

    private func applyPreferences(
        isAdBlockEnabled: Bool,
        isReturnYouTubeDislikeEnabled: Bool,
        to webView: WKWebView
    ) {
        webView.evaluateJavaScript(
            """
            (() => {
                window.youtube4macAdBlockEnabled = \(isAdBlockEnabled ? "true" : "false");
                window.youtube4macReturnYouTubeDislikeEnabled = \(isReturnYouTubeDislikeEnabled ? "true" : "false");
                window.youtube4macApplyAdBlock?.();
                window.youtube4macApplyDislikes?.();
            })();
            """
        )
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private var didInstallBlocker = false
        private var didStartInitialLoad = false
        private var isAdBlockEnabled = true
        private weak var webView: WKWebView?
        private var lastFetchedVideoID: String?

        func installContentBlocker(into controller: WKUserContentController, for webView: WKWebView, isEnabled: Bool) {
            isAdBlockEnabled = isEnabled
            self.webView = webView
            configureContentBlocker(in: controller) { [weak self] in
                self?.didInstallBlocker = true
                self?.loadIfNeeded(webView)
            }
        }

        func updateAdBlockState(_ isEnabled: Bool, for webView: WKWebView) {
            guard isAdBlockEnabled != isEnabled else { return }
            isAdBlockEnabled = isEnabled

            guard let controller = webView.configuration.userContentController as WKUserContentController? else {
                return
            }

            didInstallBlocker = false
            configureContentBlocker(in: controller) { [weak self] in
                self?.didInstallBlocker = true
                webView.reload()
            }
        }

        private func configureContentBlocker(in controller: WKUserContentController, completion: @escaping () -> Void) {
            guard let store = WKContentRuleListStore.default() else {
                DispatchQueue.main.async {
                    completion()
                }
                return
            }

            store.removeContentRuleList(forIdentifier: AppConfig.adBlockerIdentifier) { [weak self] _ in
                guard let self else { return }

                if !self.isAdBlockEnabled {
                    DispatchQueue.main.async {
                        completion()
                    }
                    return
                }

                store.compileContentRuleList(
                    forIdentifier: AppConfig.adBlockerIdentifier,
                    encodedContentRuleList: Self.contentBlockingRules
                ) { ruleList, _ in
                    DispatchQueue.main.async {
                        if let ruleList {
                            controller.add(ruleList)
                        }
                        completion()
                    }
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

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == AppConfig.returnYouTubeDislikeMessageHandler else { return }
            guard
                let body = message.body as? [String: Any],
                let videoID = body["videoId"] as? String,
                !videoID.isEmpty
            else {
                injectDislikeCount(nil, for: nil)
                return
            }

            guard lastFetchedVideoID != videoID else { return }
            lastFetchedVideoID = videoID
            fetchDislikeCount(for: videoID)
        }

        private func fetchDislikeCount(for videoID: String) {
            var components = URLComponents(url: AppConfig.returnYouTubeDislikeAPI, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "videoId", value: videoID)]
            guard let url = components?.url else { return }

            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let self else { return }
                guard
                    let data,
                    let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let dislikes = payload["dislikes"] as? NSNumber
                else {
                    self.injectDislikeCount(nil, for: videoID)
                    return
                }

                self.injectDislikeCount(dislikes.intValue, for: videoID)
            }.resume()
        }

        private func injectDislikeCount(_ dislikes: Int?, for videoID: String?) {
            DispatchQueue.main.async { [weak self] in
                guard let webView = self?.webView else { return }

                let videoArgument = videoID.map { "'\($0.replacingOccurrences(of: "'", with: "\\'"))'" } ?? "null"
                let dislikeArgument = dislikes.map(String.init) ?? "null"

                webView.evaluateJavaScript(
                    """
                    window.youtube4macSetDislikeCount?.(\(videoArgument), \(dislikeArgument));
                    """
                )
            }
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

private struct SplashToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(16)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct SettingsTabButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(tab.title)
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? .white.opacity(0.12) : .clear)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .primary : .secondary)
    }
}

private struct SettingsPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(red: 0.87, green: 0.13, blue: 0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: Color(red: 0.87, green: 0.13, blue: 0.18).opacity(configuration.isPressed ? 0.18 : 0.34), radius: configuration.isPressed ? 8 : 16, y: configuration.isPressed ? 4 : 10)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private struct SettingsSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? 0.12 : 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(configuration.isPressed ? 0.08 : 0.16), radius: configuration.isPressed ? 6 : 12, y: configuration.isPressed ? 3 : 8)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private struct CookieImportPanel: View {
    @Binding var cookieDomain: String
    @Binding var cookieText: String
    let statusMessage: String?
    let importAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import cookies")
                .font(.system(size: 16, weight: .semibold))

            Text("Paste a raw Cookie header or Netscape cookie export. Cookies import into the WebKit session used by the app.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Domain")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField(".youtube.com", text: $cookieDomain)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Cookie Data")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                TextEditor(text: $cookieText)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 180)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(action: importAction) {
                    Text("Import Cookies")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 220)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                }
                .buttonStyle(SettingsPrimaryButtonStyle())

                Spacer(minLength: 0)
            }
        }
    }
}

private struct FirstLaunchSplashView: View {
    @Binding var selectedTab: SettingsTab
    @Binding var isAdBlockEnabled: Bool
    @Binding var isReturnYouTubeDislikeEnabled: Bool
    @Binding var cookieDomain: String
    @Binding var cookieText: String
    let cookieImportStatus: String?
    let importCookies: () -> Void
    let continueAction: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.42))
                .ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("YouTube4Mac")
                        .font(.system(size: 30, weight: .bold, design: .rounded))

                    Text("Settings for playback and account session data.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        ForEach(SettingsTab.allCases) { tab in
                            SettingsTabButton(
                                tab: tab,
                                isSelected: selectedTab == tab,
                                action: { selectedTab = tab }
                            )
                        }
                    }
                    .padding(6)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    if selectedTab == .general {
                        VStack(spacing: 12) {
                            SplashToggleRow(
                                title: "Enable ad blocking",
                                subtitle: "Hide common YouTube ad surfaces and block common ad requests. Enabled by default.",
                                isOn: $isAdBlockEnabled
                            )

                            SplashToggleRow(
                                title: "Return YouTube Dislike",
                                subtitle: "Fetch dislike counts from returnyoutubedislikeapi.com and show them next to the dislike button.",
                                isOn: $isReturnYouTubeDislikeEnabled
                            )
                        }
                    } else {
                        CookieImportPanel(
                            cookieDomain: $cookieDomain,
                            cookieText: $cookieText,
                            statusMessage: cookieImportStatus,
                            importAction: importCookies
                        )
                    }

                    Button(action: continueAction) {
                        Text(selectedTab == .general ? "Done" : "Close")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(SettingsPrimaryButtonStyle())
                }
                .padding(28)

                Divider()
                    .overlay(.white.opacity(0.08))

                Link(destination: AppConfig.githubURL) {
                    Text("github.com/venusdafur/YouTube4Mac")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
            }
            .frame(width: 560)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(.white.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 30, y: 18)
            .padding(32)
        }
    }
}

struct ContentView: View {
    let appliedAdBlockEnabled: Bool
    let appliedReturnYouTubeDislikeEnabled: Bool
    let isShowingOnboarding: Bool
    let needsRestart: Bool
    @Binding var draftAdBlockEnabled: Bool
    @Binding var draftReturnYouTubeDislikeEnabled: Bool
    @Binding var selectedSettingsTab: SettingsTab
    @Binding var cookieDomain: String
    @Binding var cookieText: String
    let cookieImportStatus: String?
    let importCookies: () -> Void
    let completeOnboarding: () -> Void
    let dismissRestartPrompt: () -> Void
    let quitApp: () -> Void

    var body: some View {
        ZStack {
            WebView(
                isAdBlockEnabled: appliedAdBlockEnabled,
                isReturnYouTubeDislikeEnabled: appliedReturnYouTubeDislikeEnabled
            )
                .ignoresSafeArea()
                .blur(radius: (isShowingOnboarding || needsRestart) ? 18 : 0)
                .allowsHitTesting(!(isShowingOnboarding || needsRestart))

            if isShowingOnboarding {
                FirstLaunchSplashView(
                    selectedTab: $selectedSettingsTab,
                    isAdBlockEnabled: $draftAdBlockEnabled,
                    isReturnYouTubeDislikeEnabled: $draftReturnYouTubeDislikeEnabled,
                    cookieDomain: $cookieDomain,
                    cookieText: $cookieText,
                    cookieImportStatus: cookieImportStatus,
                    importCookies: importCookies,
                    continueAction: completeOnboarding
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            if needsRestart {
                RestartRequiredView(
                    dismissAction: dismissRestartPrompt,
                    quitAction: quitApp
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isShowingOnboarding || needsRestart)
    }
}

private struct RestartRequiredView: View {
    let dismissAction: () -> Void
    let quitAction: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.42))
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                Text("Restart Required")
                    .font(.system(size: 28, weight: .bold, design: .rounded))

                Text("Settings were saved. Restart the app to apply the new appearance or ad block configuration.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button(action: dismissAction) {
                        Text("Close")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 132)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())

                    Button(action: quitAction) {
                        Text("Quit App")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 132)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(SettingsPrimaryButtonStyle())
                }
            }
            .padding(28)
            .frame(width: 460, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(.white.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 30, y: 18)
            .padding(32)
        }
    }
}

@main
struct YouTube4MacApp: App {
    @AppStorage("isAdBlockEnabled") private var isAdBlockEnabled = true
    @AppStorage("isReturnYouTubeDislikeEnabled") private var isReturnYouTubeDislikeEnabled = true
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    @State private var appliedAdBlockEnabled = true
    @State private var appliedReturnYouTubeDislikeEnabled = true
    @State private var draftAdBlockEnabled = true
    @State private var draftReturnYouTubeDislikeEnabled = true
    @State private var isShowingSettings = false
    @State private var needsRestart = false
    @State private var selectedSettingsTab: SettingsTab = .general
    @State private var cookieDomain = ".youtube.com"
    @State private var cookieText = ""
    @State private var cookieImportStatus: String?

    init() {
        AppIconLoader.apply()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                appliedAdBlockEnabled: appliedAdBlockEnabled,
                appliedReturnYouTubeDislikeEnabled: appliedReturnYouTubeDislikeEnabled,
                isShowingOnboarding: !hasCompletedOnboarding || isShowingSettings,
                needsRestart: needsRestart,
                draftAdBlockEnabled: $draftAdBlockEnabled,
                draftReturnYouTubeDislikeEnabled: $draftReturnYouTubeDislikeEnabled,
                selectedSettingsTab: $selectedSettingsTab,
                cookieDomain: $cookieDomain,
                cookieText: $cookieText,
                cookieImportStatus: cookieImportStatus,
                importCookies: importCookies,
                completeOnboarding: completeOnboarding,
                dismissRestartPrompt: { needsRestart = false },
                quitApp: { NSApplication.shared.terminate(nil) }
            )
            .frame(minWidth: 980, minHeight: 680)
            .onAppear {
                syncAppliedState()
                syncDraftState()
            }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandMenu("Settings") {
                Button("Open Settings") {
                    syncDraftState()
                    selectedSettingsTab = .general
                    isShowingSettings = true
                    needsRestart = false
                }
            }
        }
    }

    private func syncAppliedState() {
        appliedAdBlockEnabled = isAdBlockEnabled
        appliedReturnYouTubeDislikeEnabled = isReturnYouTubeDislikeEnabled
    }

    private func syncDraftState() {
        draftAdBlockEnabled = isAdBlockEnabled
        draftReturnYouTubeDislikeEnabled = isReturnYouTubeDislikeEnabled
    }

    private func importCookies() {
        CookieImporter.importCookies(from: cookieText, defaultDomain: cookieDomain) { result in
            switch result {
            case .success(let count):
                cookieImportStatus = "Imported \(count) cookie\(count == 1 ? "" : "s"). Restart recommended before signing in."
                needsRestart = true
            case .failure(let message):
                cookieImportStatus = message
            }
        }
    }

    private func completeOnboarding() {
        let didChange =
            draftAdBlockEnabled != isAdBlockEnabled ||
            draftReturnYouTubeDislikeEnabled != isReturnYouTubeDislikeEnabled
        isAdBlockEnabled = draftAdBlockEnabled
        isReturnYouTubeDislikeEnabled = draftReturnYouTubeDislikeEnabled
        hasCompletedOnboarding = true
        isShowingSettings = false
        needsRestart = didChange
    }
}
