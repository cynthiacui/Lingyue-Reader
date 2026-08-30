import Foundation
import LingyueCore
import UIKit
import WebKit

/// One user-agent string for every WebKit surface in the app. Cloudflare binds
/// its challenge-clearance cookie to the exact UA, so the visible browser (where
/// challenges get solved) and the headless renderer (which reuses the cookie via
/// the shared default WKWebsiteDataStore) must present the same identity — a
/// mismatch silently re-challenges every headless render.
enum BrowserUserAgent {
    static let mobileSafari =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
        + "Version/17.5 Mobile/15E148 Safari/604.1"
}

/// What a headless render produced: the DOM snapshot plus the URL the
/// web view actually ended up on. `finalURL` matters because legacy CMS
/// search endpoints 302 a single-match query straight to the book's
/// detail page — the engine can only recognize that redirect if the
/// snapshot carries the post-redirect URL, not the requested one.
struct RenderedWebPage {
    let html: String
    let finalURL: URL?
}

@MainActor
final class WebRenderingService: NSObject {
    static let shared = WebRenderingService()

    private let webView: WKWebView
    private var pendingNavigation: CheckedContinuation<Void, Never>?
    private var serializer: Task<Void, Never> = Task {}
    private var isAttached = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 414, height: 896),
            configuration: configuration
        )
        webView.customUserAgent = BrowserUserAgent.mobileSafari
        super.init()
        webView.navigationDelegate = self
    }

    func render(
        at url: URL,
        settleAfter: TimeInterval = 0.8,
        timeout: TimeInterval = 6,
        challengeGrace: TimeInterval = 15
    ) async -> RenderedWebPage? {
        let previous = serializer
        let work = Task<RenderedWebPage?, Never> { @MainActor [weak self] in
            _ = await previous.value
            guard let self else { return nil }
            return await self.performRender(
                url: url,
                settleAfter: settleAfter,
                timeout: timeout,
                challengeGrace: challengeGrace
            )
        }
        serializer = Task<Void, Never> { _ = await work.value }
        return await work.value
    }

    func renderHTML(
        at url: URL,
        settleAfter: TimeInterval = 0.8,
        timeout: TimeInterval = 6
    ) async -> String? {
        await render(at: url, settleAfter: settleAfter, timeout: timeout)?.html
    }

    private func performRender(
        url: URL,
        settleAfter: TimeInterval,
        timeout: TimeInterval,
        challengeGrace: TimeInterval
    ) async -> RenderedWebPage? {
        attachToWindowIfNeeded()
        webView.stopLoading()
        resumePendingNavigation()

        webView.load(URLRequest(url: url))

        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                await withCheckedContinuation { continuation in
                    self.pendingNavigation = continuation
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
            }
            _ = await group.next()
            group.cancelAll()
            for await _ in group {}
        }
        resumePendingNavigation()

        try? await Task.sleep(for: .seconds(settleAfter))

        var html = await currentHTML()

        // Anti-bot interstitials (Cloudflare's 「请稍候…」) finish a
        // navigation of their own, so the wait above returns while the
        // challenge is still spinning — the real page arrives via a
        // *second* navigation several seconds later. Snapshotting here
        // would hand challenge HTML to the parse pipeline: zero search
        // rows, "empty" catalogs. Poll until the DOM stops looking like a
        // challenge (grace-bounded so a challenge that never clears —
        // e.g. one demanding interaction — degrades to today's behavior
        // instead of hanging the render queue).
        if let first = html, ChallengePageScreen.isChallenge(first), challengeGrace > 0 {
            let deadline = ContinuousClock.now.advanced(by: .seconds(challengeGrace))
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(500))
                guard let current = await currentHTML() else { continue }
                html = current
                if !ChallengePageScreen.isChallenge(current), !webView.isLoading {
                    // Give the real page its settle window too — late JS
                    // (chapter lists, lazy titles) lands just after load.
                    try? await Task.sleep(for: .seconds(settleAfter))
                    html = await currentHTML() ?? current
                    break
                }
            }
        }

        guard let html else { return nil }
        return RenderedWebPage(html: html, finalURL: webView.url)
    }

    private func currentHTML() async -> String? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript("document.documentElement.outerHTML") { result, _ in
                continuation.resume(returning: result as? String)
            }
        }
    }

    private func resumePendingNavigation() {
        guard let continuation = pendingNavigation else { return }
        pendingNavigation = nil
        continuation.resume()
    }

    private func attachToWindowIfNeeded() {
        guard !isAttached, webView.superview == nil else { return }
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first
        guard let window else { return }
        webView.alpha = 0.001
        webView.isUserInteractionEnabled = false
        window.addSubview(webView)
        isAttached = true
    }
}

extension WebRenderingService: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in resumePendingNavigation() }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in resumePendingNavigation() }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in resumePendingNavigation() }
    }
}
