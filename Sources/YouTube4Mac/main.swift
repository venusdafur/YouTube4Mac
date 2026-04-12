import Foundation
import SwiftUI
import WebKit

private enum AppConfig {
    static let standardHomeURL = URL(string: "https://www.youtube.com")!
    static let appleTVHomeURL = URL(string: "https://www.youtube.com/tv#/browse")!
    static let adBlockerIdentifier = "YouTube4MacAdBlock"
    static let githubURL = URL(string: "https://github.com/realcatdev/YouTube4Mac")!
    static let closeAppMessageHandler = "youtube4macCloseApp"
    static let debugMessageHandler = "youtube4macDebug"
    static let appleTVUserAgent = "Roku/DVP-9.10 (519.10E04111A)"

    static func homeURL(isAppleTVMode: Bool) -> URL {
        isAppleTVMode ? appleTVHomeURL : standardHomeURL
    }
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

private enum DebugLogger {
    static let logURLs = [
        URL(fileURLWithPath: "/Users/sonnet/Documents/Codex/YouTube4Mac/ad-debug.log"),
        URL(fileURLWithPath: "/tmp/YouTube4Mac-ad-debug.log")
    ]

    static func append(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        let data = Data(line.utf8)
        for logURL in logURLs {
            let directory = logURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: data)
                continue
            }

            guard let handle = try? FileHandle(forWritingTo: logURL) else { continue }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
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
    let isAppleTVMode: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let controller = WKUserContentController()
        controller.add(context.coordinator, name: AppConfig.closeAppMessageHandler)
        controller.add(context.coordinator, name: AppConfig.debugMessageHandler)
        controller.addUserScript(
            WKUserScript(
                source: """
                    (() => {
                        const pickTVScaleTarget = () => {
                            const candidates = [
                                document.querySelector('ytlr-guide-response-container'),
                                document.querySelector('ytlr-browse-response'),
                                document.querySelector('ytlr-home-content-renderer'),
                                document.querySelector('ytlr-section-list-renderer'),
                                document.querySelector('ytlr-rich-grid-renderer'),
                                document.querySelector('ytlr-app')
                            ].filter(Boolean);

                            if (!candidates.length) return null;

                            return candidates.reduce((widest, current) => {
                                return current.getBoundingClientRect().width > widest.getBoundingClientRect().width ? current : widest;
                            });
                        };

                        const applyTVLayout = () => {
                            const enabled = !!window.youtube4macAppleTVMode;
                            const scaleTarget = pickTVScaleTarget();

                            let style = document.getElementById('youtube4mac-tv-layout-style');
                            if (!style) {
                                style = document.createElement('style');
                                style.id = 'youtube4mac-tv-layout-style';
                                document.documentElement.appendChild(style);
                            }

                            style.textContent = enabled ? `
                                html, body {
                                    width: 100vw !important;
                                    max-width: 100vw !important;
                                    margin-left: 0 !important;
                                    margin-right: 0 !important;
                                    overflow-x: hidden !important;
                                }

                                ytlr-app,
                                ytlr-guide-response-container,
                                ytlr-browse-response,
                                ytlr-home-content-renderer,
                                ytlr-section-list-renderer,
                                ytlr-rich-grid-renderer,
                                ytlr-rich-grid-row,
                                ytlr-watch-grid,
                                #container,
                                #content,
                                #contents,
                                #page-manager {
                                    width: 100vw !important;
                                    max-width: 100vw !important;
                                    margin-left: 0 !important;
                                    margin-right: 0 !important;
                                    padding-left: 0 !important;
                                    padding-right: 0 !important;
                                    left: 0 !important;
                                    right: 0 !important;
                                }
                            ` : '';

                            document.querySelectorAll('[data-youtube4mac-tv-scaled="true"]').forEach((node) => {
                                node.style.transform = '';
                                node.style.transformOrigin = '';
                                node.style.width = '';
                                node.style.maxWidth = '';
                                node.style.marginLeft = '';
                                node.style.marginRight = '';
                                node.removeAttribute('data-youtube4mac-tv-scaled');
                            });

                            if (!enabled || !scaleTarget) {
                                return;
                            }

                            const rect = scaleTarget.getBoundingClientRect();
                            if (!rect.width || !rect.height || !Number.isFinite(rect.width) || !Number.isFinite(rect.height)) {
                                return;
                            }

                            const availableWidth = window.innerWidth;
                            const availableHeight = window.innerHeight;
                            const fittedScale = Math.max(1, Math.min(availableWidth / rect.width, availableHeight / rect.height));

                            if (fittedScale <= 1.01) {
                                return;
                            }

                            scaleTarget.setAttribute('data-youtube4mac-tv-scaled', 'true');
                            scaleTarget.style.transformOrigin = 'top left';
                            scaleTarget.style.transform = `scale(${fittedScale})`;
                            scaleTarget.style.width = `${availableWidth / fittedScale}px`;
                            scaleTarget.style.maxWidth = `${availableWidth / fittedScale}px`;
                            scaleTarget.style.marginLeft = '0';
                            scaleTarget.style.marginRight = '0';
                        };

                        window.youtube4macApplyTVLayout = applyTVLayout;
                        applyTVLayout();
                        window.addEventListener('resize', applyTVLayout);
                        new MutationObserver(applyTVLayout).observe(document.documentElement, {
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
                        const closeApp = () => {
                            window.webkit?.messageHandlers?.\(AppConfig.closeAppMessageHandler)?.postMessage({});
                        };

                        window.close = closeApp;
                        window.youtube4macCloseApp = closeApp;

                        const selectors = [
                            'ytd-display-ad-renderer',
                            'ytd-ad-slot-renderer',
                            'ytd-player-legacy-desktop-watch-ads-renderer',
                            'ytd-engagement-panel-section-list-renderer[target-id*="engagement-panel-ads"]',
                            'ytd-banner-promo-renderer',
                            'ytd-statement-banner-renderer',
                            'ytd-reel-video-renderer ytd-ad-slot-renderer',
                            'ytd-video-masthead-ad-v3-renderer',
                            'ytd-in-feed-ad-layout-renderer',
                            'ytd-rich-item-renderer:has(ytd-display-ad-renderer)',
                            'ytd-rich-item-renderer:has(ytd-ad-slot-renderer)',
                            'ytm-promoted-sparkles-web-renderer',
                            '.ytd-promoted-sparkles-web-renderer',
                            '.ytp-ad-module',
                            '.ytp-ad-overlay-container',
                            '.ytp-ad-message-container',
                            '.ytp-ad-image-overlay',
                            '.ytp-featured-product',
                            '.ytp-suggested-action-badge',
                            '.ytp-ad-player-overlay',
                            '.ytp-ad-survey',
                            '.ytp-ad-text',
                            '.ytp-ad-preview-container',
                            '.video-ads',
                            '.masthead-ad-control',
                            '.sparkles-light-cta',
                            '.companion-ad-container',
                            '.ad-container',
                            '.ytd-in-feed-ad-layout-renderer',
                            '[layout*="display-ad-renderer"]',
                            '[class*="ytd-display-ad-renderer"]'
                        ];

                        const sponsoredContainerSelectors = [
                            'ytd-rich-grid-media',
                            'ytd-rich-item-renderer',
                            'ytd-rich-grid-renderer #contents > *',
                            'ytd-rich-shelf-renderer',
                            'ytd-shelf-renderer',
                            'ytd-horizontal-card-list-renderer > *',
                            'ytd-compact-promoted-video-renderer',
                            'ytd-video-renderer',
                            'ytd-compact-video-renderer',
                            'ytd-grid-video-renderer',
                            'ytlr-rich-grid-row > *',
                            'ytlr-rich-grid-renderer > *',
                            'ytlr-item-section-renderer > *',
                            'ytlr-section-list-renderer > *',
                            'ytlr-guide-response-container > *'
                        ];

                        const homepageAdTextPatterns = [
                            /(^|\\s)sponsored(\\s|$)/i,
                            /press and hold for ad options/i,
                            /advertiser survey/i,
                            /why this ad/i,
                            /ad choices/i,
                            /visit advertiser/i,
                            /promoted/i,
                            /free with ads/i,
                            /shop now/i,
                            /install now/i,
                            /learn more/i
                        ];

                        const isHomepageLike = () => {
                            const path = window.location.pathname || '/';
                            return path === '/' || path.startsWith('/feed/') || path.startsWith('/@');
                        };

                        const homepageContainerTagNames = new Set([
                            'YTD-RICH-ITEM-RENDERER',
                            'YTD-RICH-GRID-MEDIA',
                            'YTD-VIDEO-RENDERER',
                            'YTD-COMPACT-VIDEO-RENDERER',
                            'YTD-GRID-VIDEO-RENDERER',
                            'YTD-RICH-SECTION-RENDERER',
                            'YTD-RICH-SHELF-RENDERER',
                            'YTD-SHELF-RENDERER',
                            'YTD-HORIZONTAL-CARD-LIST-RENDERER',
                            'YTD-REEL-SHELF-RENDERER',
                            'YTD-ITEM-SECTION-RENDERER',
                            'YTD-STATEMENT-BANNER-RENDERER',
                            'YTD-BANNER-PROMO-RENDERER',
                            'YTLR-RICH-GRID-ROW',
                            'YTLR-RICH-GRID-RENDERER',
                            'YTLR-ITEM-SECTION-RENDERER',
                            'YTLR-SECTION-LIST-RENDERER',
                            'YTLR-GUIDE-RESPONSE-CONTAINER',
                            'YTLR-HOME-CONTENT-RENDERER',
                            'YTLR-BROWSE-RESPONSE',
                            'YTLR-CONTENT-ITEM-RENDERER',
                            'YTLR-RICH-ITEM-RENDERER',
                            'YTLR-TILE-RENDERER'
                        ]);

                        const closestHomepageContainer = (node) => {
                            let current = node instanceof Element ? node : null;

                            while (current) {
                                if (homepageContainerTagNames.has(current.tagName)) {
                                    return current;
                                }

                                if (
                                    current instanceof HTMLElement &&
                                    current.parentElement &&
                                    current.parentElement.id === 'contents'
                                ) {
                                    return current;
                                }

                                current = current.parentElement;
                            }

                            return null;
                        };

                        const removeHomepageContainer = (node) => {
                            const container = closestHomepageContainer(node);
                            if (container) {
                                container.remove();
                                return;
                            }

                            if (node instanceof HTMLElement) {
                                node.remove();
                            }
                        };

                        const debugDescribeNode = (node) => {
                            if (!(node instanceof Element)) return null;

                            const describe = (element) => {
                                const tag = element.tagName.toLowerCase();
                                const id = element.id ? `#${element.id}` : '';
                                const classes = Array.from(element.classList || []).slice(0, 4).map((name) => `.${name}`).join('');
                                const text = (element.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 180);
                                return { tag, id, classes, text };
                            };

                            const chain = [];
                            let current = node;
                            let depth = 0;
                            while (current && current instanceof Element && depth < 10) {
                                chain.push(describe(current));
                                current = current.parentElement;
                                depth += 1;
                            }

                            return {
                                location: window.location.href,
                                marker: (node.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 180),
                                nearestContainer: closestHomepageContainer(node)?.tagName?.toLowerCase() || null,
                                chain
                            };
                        };

                        const sendDebug = (payload) => {
                            window.webkit?.messageHandlers?.\(AppConfig.debugMessageHandler)?.postMessage(payload);
                        };

                        const sentDebugKeys = new Set();
                        const sendDebugOnce = (payload) => {
                            if (!payload) return;
                            const key = JSON.stringify(payload);
                            if (sentDebugKeys.has(key)) return;
                            sentDebugKeys.add(key);
                            sendDebug(payload);
                        };

                        sendDebug({
                            event: 'debug-ready',
                            location: window.location.href,
                            title: document.title
                        });

                        const ensureStyle = () => {
                            let style = document.getElementById('youtube4mac-adblock-style');
                            if (!style) {
                                style = document.createElement('style');
                                style.id = 'youtube4mac-adblock-style';
                                document.documentElement.appendChild(style);
                            }
                            style.textContent = window.youtube4macAdBlockEnabled
                                ? `${selectors.join(',')}, .ad-showing .html5-video-player .ytp-gradient-top, .ad-showing .html5-video-player .ytp-gradient-bottom { display: none !important; visibility: hidden !important; opacity: 0 !important; }`
                                : '';
                        };

                        const skipActiveVideoAd = () => {
                            const video = document.querySelector('video');
                            const player = document.getElementById('movie_player');
                            const isAdShowing =
                                !!document.querySelector('.ad-showing') ||
                                !!document.querySelector('.ytp-ad-player-overlay') ||
                                !!document.querySelector('.video-ads');

                            if (!isAdShowing) {
                                return;
                            }

                            document.querySelector('.ytp-ad-skip-button, .ytp-skip-ad-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button-modern')?.click();
                            document.querySelector('.ytp-ad-overlay-close-button, .ytp-ad-overlay-close-container button')?.click();

                            if (player && typeof player.seekTo === 'function') {
                                try {
                                    const duration = typeof player.getDuration === 'function' ? Number(player.getDuration()) : 0;
                                    if (duration > 0) {
                                        player.seekTo(Math.max(0, duration - 0.25), true);
                                    }
                                } catch {}
                            }

                            if (video) {
                                const duration = Number.isFinite(video.duration) ? video.duration : 0;
                                if (duration > 0) {
                                    video.currentTime = Math.max(0, duration - 0.25);
                                } else {
                                    video.currentTime = 9999;
                                }
                                video.muted = true;
                                video.playbackRate = 16;
                            }

                            document.documentElement.classList.remove('ad-showing');
                            document.body?.classList?.remove('ad-showing');
                        };

                        const hideAds = () => {
                            ensureStyle();
                            if (!window.youtube4macAdBlockEnabled) return;

                            if (isHomepageLike()) {
                                document.querySelectorAll('yt-formatted-string, span, div, a, button').forEach((node) => {
                                    if (!(node instanceof HTMLElement)) return;
                                    const text = (node.innerText || '').replace(/\\s+/g, ' ').trim();
                                    if (!text) return;

                                    if (homepageAdTextPatterns.some((pattern) => pattern.test(text))) {
                                        sendDebugOnce({
                                            event: 'homepage-marker-match',
                                            ...debugDescribeNode(node)
                                        });
                                    }
                                });
                            }

                            selectors.forEach((selector) => {
                                document.querySelectorAll(selector).forEach((node) => node.remove());
                            });

                            document.querySelectorAll('[class*="ad-"], [id*="ad-"], [id^="ad_"]').forEach((node) => {
                                if (
                                    node instanceof HTMLElement &&
                                    /banner|masthead|companion|promoted|sponsor/i.test(node.className + ' ' + node.id)
                                ) {
                                    node.remove();
                                }
                            });

                            document.querySelectorAll('ytd-rich-item-renderer, ytd-compact-video-renderer, ytd-video-renderer').forEach((node) => {
                                const text = (node.textContent || '').replace(/\\s+/g, ' ').trim();
                                if (
                                    node.querySelector('ytd-display-ad-renderer, ytd-ad-slot-renderer, [badge-style-type=\"BADGE_STYLE_TYPE_AD\"]') ||
                                    homepageAdTextPatterns.some((pattern) => pattern.test(text)) ||
                                    node.querySelector('[aria-label*="Sponsored"], [aria-label*="Promoted"], [title*="Sponsored"], [title*="Promoted"]')
                                ) {
                                    node.remove();
                                }
                            });

                            if (isHomepageLike()) {
                                document.querySelectorAll('yt-formatted-string, span, div, a, button').forEach((node) => {
                                    if (!(node instanceof HTMLElement)) return;
                                    const text = (node.innerText || '').replace(/\\s+/g, ' ').trim();
                                    if (text && homepageAdTextPatterns.some((pattern) => pattern.test(text))) {
                                        sendDebugOnce({
                                            event: 'homepage-remove-text-node',
                                            ...debugDescribeNode(node)
                                        });
                                        removeHomepageContainer(node);
                                    }
                                });

                                document.querySelectorAll(sponsoredContainerSelectors.join(',')).forEach((node) => {
                                    const text = (node.textContent || '').replace(/\\s+/g, ' ').trim();
                                    if (
                                        homepageAdTextPatterns.some((pattern) => pattern.test(text)) ||
                                        node.querySelector('ytd-display-ad-renderer, ytd-ad-slot-renderer, ytd-promoted-video-renderer, ytd-promoted-sparkles-text-search-renderer') ||
                                        node.querySelector('[aria-label*="Sponsored"], [aria-label*="Promoted"], [title*="Sponsored"], [title*="Promoted"]')
                                    ) {
                                        sendDebugOnce({
                                            event: 'homepage-remove-container',
                                            ...debugDescribeNode(node)
                                        });
                                        removeHomepageContainer(node);
                                    }
                                });
                            }

                            document.querySelectorAll('ytd-rich-section-renderer, ytd-statement-banner-renderer, ytd-banner-promo-renderer').forEach((node) => {
                                const text = (node.textContent || '').replace(/\\s+/g, ' ').trim();
                                if (
                                    homepageAdTextPatterns.some((pattern) => pattern.test(text)) ||
                                    /try|offer|deal/i.test(text)
                                ) {
                                    node.remove();
                                }
                            });

                            if (isHomepageLike()) {
                                document.querySelectorAll('[aria-label*="Sponsored"], [aria-label*="Promoted"], [title*="Sponsored"], [title*="Promoted"]').forEach((node) => {
                                    sendDebugOnce({
                                        event: 'homepage-remove-aria',
                                        ...debugDescribeNode(node)
                                    });
                                    removeHomepageContainer(node);
                                });

                                document.querySelectorAll('*').forEach((node) => {
                                    if (!(node instanceof HTMLElement)) return;
                                    if (node.children.length > 12) return;

                                    const text = (node.innerText || '').replace(/\\s+/g, ' ').trim();
                                    if (homepageAdTextPatterns.some((pattern) => pattern.test(text))) {
                                        sendDebugOnce({
                                            event: 'homepage-remove-generic',
                                            ...debugDescribeNode(node)
                                        });
                                        removeHomepageContainer(node);
                                    }
                                });
                            }

                            skipActiveVideoAd();
                        };

                        window.youtube4macApplyAdBlock = () => {
                            hideAds();
                        };

                        hideAds();
                        setInterval(hideAds, 350);
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
        webView.customUserAgent = isAppleTVMode ? AppConfig.appleTVUserAgent : nil
        context.coordinator.installContentBlocker(
            into: controller,
            for: webView,
            isEnabled: true,
            isAppleTVMode: isAppleTVMode
        )
        applyPreferences(
            isAdBlockEnabled: true,
            isAppleTVMode: isAppleTVMode,
            to: webView
        )
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.updateDeviceMode(isAppleTVMode, for: nsView)
        applyPreferences(
            isAdBlockEnabled: true,
            isAppleTVMode: isAppleTVMode,
            to: nsView
        )
        context.coordinator.loadIfNeeded(nsView)
    }

    private func applyPreferences(
        isAdBlockEnabled: Bool,
        isAppleTVMode: Bool,
        to webView: WKWebView
    ) {
        webView.evaluateJavaScript(
            """
            (() => {
                window.youtube4macAdBlockEnabled = \(isAdBlockEnabled ? "true" : "false");
                window.youtube4macAppleTVMode = \(isAppleTVMode ? "true" : "false");
                window.youtube4macApplyAdBlock?.();
                window.youtube4macApplyTVLayout?.();
            })();
            """
        )
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private var didInstallBlocker = false
        private var didStartInitialLoad = false
        private var isAdBlockEnabled = true
        private var isAppleTVMode = false
        private weak var webView: WKWebView?

        func installContentBlocker(
            into controller: WKUserContentController,
            for webView: WKWebView,
            isEnabled: Bool,
            isAppleTVMode: Bool
        ) {
            isAdBlockEnabled = isEnabled
            self.isAppleTVMode = isAppleTVMode
            self.webView = webView
            configureContentBlocker(in: controller) { [weak self] in
                self?.didInstallBlocker = true
                self?.loadIfNeeded(webView)
            }
        }

        func updateDeviceMode(_ isAppleTVMode: Bool, for webView: WKWebView) {
            guard self.isAppleTVMode != isAppleTVMode else { return }
            self.isAppleTVMode = isAppleTVMode
            webView.customUserAgent = isAppleTVMode ? AppConfig.appleTVUserAgent : nil
            webView.load(URLRequest(url: AppConfig.homeURL(isAppleTVMode: isAppleTVMode)))
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
            webView.load(URLRequest(url: AppConfig.homeURL(isAppleTVMode: isAppleTVMode)))
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
            if message.name == AppConfig.closeAppMessageHandler {
                DispatchQueue.main.async {
                    NSApplication.shared.terminate(nil)
                }
                return
            }

            if message.name == AppConfig.debugMessageHandler {
                DebugLogger.append(String(describing: message.body))
                return
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
                  "url-filter": "https?://([A-Za-z0-9.-]+\\\\.)?youtube\\\\.com/pagead/.*"
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
                  "url-filter": "https?://([A-Za-z0-9.-]+\\\\.)?youtubei\\\\.googleapis\\\\.com/youtubei/v1/log_event.*"
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
                  "selector": "ytd-display-ad-renderer, ytd-ad-slot-renderer, ytd-video-masthead-ad-v3-renderer, ytd-in-feed-ad-layout-renderer, ytm-promoted-sparkles-web-renderer, .ytd-promoted-sparkles-web-renderer, .ytp-ad-overlay-container, .ytp-ad-message-container, .ytp-ad-image-overlay, .ytp-ad-module, .video-ads, ytd-banner-promo-renderer"
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
    @Binding var isAppleTVMode: Bool
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
                                title: "Report as Apple TV",
                                subtitle: "Tell YouTube the device is an Apple TV so it loads the TV layout and metadata.",
                                isOn: $isAppleTVMode
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
                    Text("github.com/realcatdev/YouTube4Mac")
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
    let appliedAppleTVMode: Bool
    let isShowingOnboarding: Bool
    let needsRestart: Bool
    @Binding var draftAppleTVMode: Bool
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
                isAppleTVMode: appliedAppleTVMode
            )
                .ignoresSafeArea()
                .blur(radius: (isShowingOnboarding || needsRestart) ? 18 : 0)
                .allowsHitTesting(!(isShowingOnboarding || needsRestart))

            if isShowingOnboarding {
                FirstLaunchSplashView(
                    selectedTab: $selectedSettingsTab,
                    isAppleTVMode: $draftAppleTVMode,
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

                Text("Settings were saved. Restart the app to apply the new configuration.")
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
    @AppStorage("isAppleTVMode") private var isAppleTVMode = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    @State private var appliedAppleTVMode = false
    @State private var draftAppleTVMode = false
    @State private var isShowingSettings = false
    @State private var needsRestart = false
    @State private var selectedSettingsTab: SettingsTab = .general
    @State private var cookieDomain = ".youtube.com"
    @State private var cookieText = ""
    @State private var cookieImportStatus: String?

    init() {
        let defaults = UserDefaults.standard
        let savedAppleTVMode = defaults.object(forKey: "isAppleTVMode") as? Bool ?? false

        _appliedAppleTVMode = State(initialValue: savedAppleTVMode)
        _draftAppleTVMode = State(initialValue: savedAppleTVMode)
        AppIconLoader.apply()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                appliedAppleTVMode: appliedAppleTVMode,
                isShowingOnboarding: !hasCompletedOnboarding || isShowingSettings,
                needsRestart: needsRestart,
                draftAppleTVMode: $draftAppleTVMode,
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
        .windowResizability(.automatic)
        .defaultSize(width: 1440, height: 900)
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
        appliedAppleTVMode = isAppleTVMode
    }

    private func syncDraftState() {
        draftAppleTVMode = isAppleTVMode
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
        let didChange = draftAppleTVMode != isAppleTVMode
        isAppleTVMode = draftAppleTVMode
        hasCompletedOnboarding = true
        isShowingSettings = false
        needsRestart = didChange
    }
}
