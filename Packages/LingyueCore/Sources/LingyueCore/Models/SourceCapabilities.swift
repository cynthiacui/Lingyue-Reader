import Foundation

/// What a `BookSource` can do. The Discovery search bar consults this to
/// build its fan-out set; the in-app browser consults this to decide
/// whether to offer "Import" on a given page; the reader consults this to
/// decide whether to call `fetchChapter` synchronously vs. show a "Open
/// in browser" affordance. Carrying capability state in the source — not
/// inferring it from `BookSourceError` thrown at call time — keeps the UI
/// affordances honest before the user hits the failure path.
public struct SourceCapabilities: Codable, Sendable, Hashable {
    /// `true` when `BookSource.search(_:)` is implemented and the source
    /// site exposes a usable search endpoint. Browser-only sources (the
    /// ones gated by Cloudflare or a JS challenge that the rule engine
    /// can't pre-clear) set this to `false`.
    public var supportsSearch: Bool

    /// `true` when this source should appear in the Discovery search bar's
    /// fan-out. A source can `supportsSearch` and still set this to
    /// `false` — e.g., expensive sources kept out of fan-out but reachable
    /// from a dedicated picker.
    public var showInSearchBar: Bool

    /// `true` when the source's `detectBook(in:)` can recognize a book
    /// detail page from a `WebPageSnapshot`. Powers the in-app browser's
    /// Import affordance.
    public var supportsBrowserImport: Bool

    /// `true` when at least one of the per-step engines requires the
    /// headless renderer. Surfaced to UI so the search bar can warn before
    /// fanning out to a costly source.
    public var requiresWebRender: Bool

    /// Soft cap on concurrent in-flight requests this source's host can
    /// tolerate. Engine respects this in fan-out scenarios.
    public var maxConcurrentRequests: Int

    /// Minimum delay between sequential requests to the same host, in
    /// milliseconds. `0` disables throttling.
    public var requestIntervalMillis: Int

    public init(
        supportsSearch: Bool,
        showInSearchBar: Bool,
        supportsBrowserImport: Bool,
        requiresWebRender: Bool,
        maxConcurrentRequests: Int = 3,
        requestIntervalMillis: Int = 0
    ) {
        self.supportsSearch = supportsSearch
        self.showInSearchBar = showInSearchBar
        self.supportsBrowserImport = supportsBrowserImport
        self.requiresWebRender = requiresWebRender
        self.maxConcurrentRequests = maxConcurrentRequests
        self.requestIntervalMillis = requestIntervalMillis
    }
}
