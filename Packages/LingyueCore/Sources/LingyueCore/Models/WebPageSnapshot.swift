import Foundation

/// A page the rule engine can parse — usually the result of a fetch or a
/// headless render, occasionally synthesized from disk in tests. Carries
/// the decoded HTML, the final URL after redirects (for relative URL
/// resolution), and an optional set of response headers from the HTTP
/// layer. `WKWebView` renders fill in only `html` and `finalURL`.
public struct WebPageSnapshot: Sendable, Hashable {
    /// Decoded HTML, after `SourceEncoding` was applied.
    public var html: String

    /// The URL the response actually came from, post-redirect. The engine
    /// uses this as the base for resolving relative hrefs and for keying
    /// per-host throttles.
    public var finalURL: URL

    /// HTTP response headers, lower-cased keys. Empty for renderer-sourced
    /// snapshots (the web view doesn't surface the underlying request's
    /// headers in a useful way).
    public var responseHeaders: [String: String]

    /// HTTP status code, if known. `nil` for renderer-sourced snapshots.
    public var statusCode: Int?

    public init(
        html: String,
        finalURL: URL,
        responseHeaders: [String: String] = [:],
        statusCode: Int? = nil
    ) {
        self.html = html
        self.finalURL = finalURL
        self.responseHeaders = responseHeaders
        self.statusCode = statusCode
    }
}
