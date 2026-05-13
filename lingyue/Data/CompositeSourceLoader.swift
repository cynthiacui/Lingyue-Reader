import Foundation
import LingyueCore

/// `SourceHTMLLoading` that routes per request engine. Plain fetches go
/// to a cheap HTTP loader; renders go to a `WKWebView`-backed loader.
/// Runtime constructs one of these and hands it to every
/// `RuleBasedBookSource` — the rule's `enginePerStep` already decides
/// which method the engine calls, so this loader's job is just to forward.
struct CompositeSourceLoader: SourceHTMLLoading {
    let http: any SourceHTMLLoading
    let web: any SourceHTMLLoading

    init(
        http: any SourceHTMLLoading = HTTPSourceLoader(
            defaultUserAgent: CompositeSourceLoader.defaultUserAgent
        ),
        web: any SourceHTMLLoading = WebViewSourceLoader()
    ) {
        self.http = http
        self.web = web
    }

    func fetchHTML(_ request: SourceRequest) async throws -> WebPageSnapshot {
        try await http.fetchHTML(request)
    }

    func renderHTML(_ request: SourceRequest) async throws -> WebPageSnapshot {
        try await web.renderHTML(request)
    }

    /// Mobile-Safari UA matching what `WebRenderingService` uses, so HTTP
    /// fetches and rendered fetches present a consistent client identity.
    static let defaultUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 "
        + "Mobile/15E148 Safari/604.1"
}
