import Foundation

/// One HTTP/web request the engine wants to issue. Built by the rule
/// interpreter from a `SourceRule` step; consumed by `SourceHTMLLoading`.
/// All fields are immutable, all values are plain — the loader does not
/// reach into the rule schema. Keeps the rule-engine boundary clean and
/// the loader trivially mockable.
public struct SourceRequest: Sendable, Hashable {
    public enum Method: String, Sendable, Hashable {
        case get = "GET"
        case post = "POST"
    }

    /// Fully-resolved absolute URL the request targets. Relative URLs are
    /// resolved by the engine before constructing the request, so the
    /// loader can trust this is absolute.
    public var url: URL

    public var method: Method

    /// Headers to apply on top of the loader's defaults (User-Agent etc.).
    /// Order is irrelevant; duplicates resolve in last-wins fashion.
    public var headers: [String: String]

    /// Body bytes for `POST`. `nil` for `GET`. Encoding is the caller's
    /// responsibility — the loader writes these bytes verbatim.
    public var body: Data?

    /// Encoding hint passed straight through to the body decoder. `.auto`
    /// is the default and matches Apple's behaviour for headers-driven
    /// detection.
    public var encoding: SourceEncoding

    /// Optional referer. Some sites 403 on missing referer; this keeps the
    /// rule editor from having to spell out a header dict for the common
    /// case.
    public var referer: URL?

    public init(
        url: URL,
        method: Method = .get,
        headers: [String: String] = [:],
        body: Data? = nil,
        encoding: SourceEncoding = .auto,
        referer: URL? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.encoding = encoding
        self.referer = referer
    }
}
