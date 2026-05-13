import Foundation

/// Per-step loader selection: a rule can declare that search needs the
/// headless renderer (Cloudflare challenge in front of a search form) while
/// chapter pages can be fetched plain — or vice-versa. Defaults to `.http`
/// for everything when omitted, which matches the common case.
public struct EnginePerStep: Codable, Sendable, Hashable {
    public enum Engine: String, Codable, Sendable, Hashable {
        /// Plain HTTP fetch via `SourceHTMLLoading.fetchHTML`.
        case http
        /// Headless `WKWebView` render via `SourceHTMLLoading.renderHTML`.
        case web
    }

    public var search: Engine
    public var detail: Engine
    public var catalog: Engine
    public var chapter: Engine

    public init(
        search: Engine = .http,
        detail: Engine = .http,
        catalog: Engine = .http,
        chapter: Engine = .http
    ) {
        self.search = search
        self.detail = detail
        self.catalog = catalog
        self.chapter = chapter
    }

    /// All-`.http` default — used when a rule omits the field entirely.
    public static let `default` = EnginePerStep()
}
