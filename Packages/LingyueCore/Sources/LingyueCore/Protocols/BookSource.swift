import Foundation

/// A usable source at runtime — searchable, browsable, and able to resolve
/// detail/catalog/chapter pages. Constructed from a `SourceRule` (the
/// rule-driven `RuleBasedBookSource`) or from a hand-written internal
/// adapter (`LingyueInternalSources`). Consumers — Discovery search bar,
/// reader, import flow — only see this protocol; they never reach
/// `SourceRule` directly. That keeps editing concerns (`EditableSourceStore`)
/// orthogonal to runtime concerns.
public protocol BookSource: Sendable {
    /// Stable, namespaced identifier. User rules use `rule:<uuid>`,
    /// internal adapters use `internal:<slug>`. Stable across launches so
    /// it can key caches, group search results, and survive diagnostics
    /// without exposing UUIDs to the user.
    var id: String { get }

    /// Display name shown in source pickers, search-result groupings, and
    /// diagnostics. User-editable for rule-based sources; fixed for
    /// internal adapters.
    var displayName: String { get }

    /// Declares what this source can do — programmatic search vs. browse-only,
    /// whether any step requires the in-app browser, etc. Reading this is the
    /// canonical way to decide if a source belongs in the Discovery search
    /// fan-out.
    var capabilities: SourceCapabilities { get }

    /// Programmatic search. Sources without search capability throw
    /// `BookSourceError.searchUnsupported`. Implementations should respect
    /// rate limits declared in `capabilities`.
    func search(_ query: String) async throws -> [BookSearchResult]

    /// Probe a rendered web page to see if it's a recognizable book detail
    /// page for this source. Used by the in-app browser's
    /// "Import" affordance: as the user wanders, every page load is checked
    /// against every enabled source's detector.
    func detectBook(in page: WebPageSnapshot) async throws -> BookDetection?

    /// Resolve a known book-detail URL to a full `BookDetail` value.
    func fetchDetail(url: URL) async throws -> BookDetail

    /// Resolve a known catalog URL to its chapter list. Pagination is
    /// handled internally; the returned array spans all catalog pages.
    func fetchCatalog(url: URL) async throws -> [ChapterLink]

    /// Resolve a single chapter page to its title + body content.
    func fetchChapter(url: URL) async throws -> ChapterContent
}

/// Errors a `BookSource` may throw. Kept narrow on purpose — UI surfaces
/// these with translated user-facing messages; do not encode prose here.
public enum BookSourceError: Error, Sendable, Hashable {
    case searchUnsupported
    case detectionUnsupported
    case unsupportedURL(URL)
    case loadFailed(reason: String)
    case parseFailed(field: String)
    case ruleIncomplete(field: String)
    case rateLimited
    case sourceBlocked
}
