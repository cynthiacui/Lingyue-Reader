import Foundation

/// One row in a search result list, returned by `BookSource.search`.
/// Intentionally compact — the search list view doesn't need full chapter
/// data, only enough to render the cell and pivot into `fetchDetail`.
public struct BookSearchResult: Sendable, Hashable, Codable {
    /// Title as the source shows it. Engine applies the rule's transforms
    /// before populating this, so it's display-ready.
    public var title: String

    /// Author string, source-as-shown. Some sources omit this on the
    /// search page; in that case it's `nil` and the detail page fills it
    /// in later.
    public var author: String?

    /// Optional cover thumbnail. Sources without thumbnails leave this
    /// `nil`; the UI falls back to a generated placeholder.
    public var coverURL: URL?

    /// Optional one-line summary. Some sources show a snippet on the
    /// search results page — surface it when present.
    public var snippet: String?

    /// The book detail page URL. Required — the cell tap target depends
    /// on this. Engine has already resolved it to absolute.
    public var detailURL: URL

    /// Stable namespaced source ID — `rule:<uuid>` or `internal:<slug>`.
    /// Lets aggregated search results stay groupable across launches.
    public var sourceID: String

    public init(
        title: String,
        author: String? = nil,
        coverURL: URL? = nil,
        snippet: String? = nil,
        detailURL: URL,
        sourceID: String
    ) {
        self.title = title
        self.author = author
        self.coverURL = coverURL
        self.snippet = snippet
        self.detailURL = detailURL
        self.sourceID = sourceID
    }
}
