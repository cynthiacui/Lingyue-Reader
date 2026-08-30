import Foundation
import LingyueCore
import WebKit

/// `WKWebView`-backed `SourceHTMLLoading`. Wraps `WebRenderingService` so
/// rule steps marked `.web` (Cloudflare JS challenges, client-rendered
/// pages) get a real headless render. After every render we copy the WK
/// cookie jar into `HTTPCookieStorage.shared` — the two stores do not
/// auto-share, and downstream plain HTTP loads need the post-challenge
/// session cookies to ride along.
///
/// On its own this loader implements `fetchHTML` by delegating to
/// `renderHTML`; runtime composes it with `HTTPSourceLoader` via
/// `CompositeSourceLoader` so plain HTTP steps stay cheap.
struct WebViewSourceLoader: SourceHTMLLoading {
    let settleAfter: TimeInterval
    let timeout: TimeInterval

    init(
        settleAfter: TimeInterval = 0.8,
        timeout: TimeInterval = 6
    ) {
        self.settleAfter = settleAfter
        self.timeout = timeout
    }

    func fetchHTML(_ request: SourceRequest) async throws -> WebPageSnapshot {
        try await renderHTML(request)
    }

    func renderHTML(_ request: SourceRequest) async throws -> WebPageSnapshot {
        let url = request.url
        guard let page = await WebRenderingService.shared.render(
            at: url,
            settleAfter: settleAfter,
            timeout: timeout
        ) else {
            throw BookSourceError.loadFailed(reason: "WKWebView render returned no HTML")
        }
        await Self.syncWKCookiesToHTTPStorage()
        // Prefer the web view's own post-redirect URL: single-match search
        // redirects (search endpoint → book detail page) are invisible to
        // the engine unless the snapshot reports where the render landed.
        return WebPageSnapshot(html: page.html, finalURL: page.finalURL ?? url)
    }

    /// Copies every cookie from `WKWebsiteDataStore.default().httpCookieStore`
    /// into `HTTPCookieStorage.shared`. One-way sync: WK is the source of
    /// truth after a render. Idempotent — calling repeatedly just refreshes.
    @MainActor
    static func syncWKCookiesToHTTPStorage() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
        for cookie in cookies {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }
}
