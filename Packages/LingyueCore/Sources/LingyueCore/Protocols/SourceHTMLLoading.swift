import Foundation

/// Loader abstraction the rule engine uses to obtain page bytes + a parsed
/// snapshot. Two flavours, deliberately separate so the engine can declare
/// which it needs per step:
///
/// - `fetchHTML`: a plain HTTP fetch with the request's headers/encoding
///   applied. Cheap. Returns the raw response. Used when a site renders
///   its content server-side.
/// - `renderHTML`: a headless `WKWebView` render. Expensive. Used when
///   pages require JS execution before the desired DOM exists, or when an
///   anti-bot challenge needs the browser stack to clear.
///
/// LingyueCore intentionally does not import `WebKit`/`UIKit`. Concrete
/// adapters live in the app target, where the headless renderer can wrap
/// `WebRenderingService`. Tests inject a stub that returns canned snapshots
/// from disk, which is what makes the rule engine unit-testable.
public protocol SourceHTMLLoading: Sendable {
    /// Issue an `HTTP` request and return the decoded body + the final URL
    /// after redirects. Implementations apply `request.encoding`,
    /// `request.headers`, and any cookie jar attached to the loader.
    func fetchHTML(_ request: SourceRequest) async throws -> WebPageSnapshot

    /// Render `request` in a headless web view and return the post-script
    /// DOM as HTML, plus the final URL after any client-side navigations.
    /// Use only when the rule's `enginePerStep` selects `.web` for the
    /// relevant step — `WKWebView` instantiation is the dominant cost.
    func renderHTML(_ request: SourceRequest) async throws -> WebPageSnapshot
}
