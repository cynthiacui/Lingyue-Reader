import Foundation

/// Full book metadata, returned by `BookSource.fetchDetail`. The import
/// flow stores this on the local `LibraryStore` row; the reader presents
/// fields like description, tags, and serializing state in chrome around
/// the chapter body.
public struct BookDetail: Sendable, Hashable, Codable {
    /// Title as the source shows it.
    public var title: String

    /// Author, when the detail page exposes one. Sources that don't expose
    /// an author leave this `nil`.
    public var author: String?

    /// Cover image URL. May be `nil` when the source doesn't carry one.
    public var coverURL: URL?

    /// Long-form description / synopsis, paragraph-broken with `\n\n`.
    /// Source-as-shown after transforms.
    public var description: String?

    /// Free-form tags / category labels, in source order. Empty when none.
    public var tags: [String]

    /// "完结" / "连载中" / similar status string the source uses. Display
    /// only — engine doesn't interpret.
    public var status: String?

    /// Word count or chapter count the source reports, if any. Stringly
    /// typed because sources vary ("142万字", "1284章", "Updated 2026-04-12").
    public var statistics: String?

    /// URL of the chapter catalog page. `BookSource.fetchCatalog` accepts
    /// this directly. Frequently the same as `detailURL` for sources that
    /// list chapters on the detail page itself.
    public var catalogURL: URL

    /// URL of the detail page itself, kept on the model so callers can
    /// open the source in a browser tab or re-resolve on schema drift.
    public var detailURL: URL

    /// Stable namespaced source ID. Engine fills this from the resolving
    /// `BookSource.id`; consumers shouldn't need to set it manually.
    public var sourceID: String

    public init(
        title: String,
        author: String? = nil,
        coverURL: URL? = nil,
        description: String? = nil,
        tags: [String] = [],
        status: String? = nil,
        statistics: String? = nil,
        catalogURL: URL,
        detailURL: URL,
        sourceID: String
    ) {
        self.title = title
        self.author = author
        self.coverURL = coverURL
        self.description = description
        self.tags = tags
        self.status = status
        self.statistics = statistics
        self.catalogURL = catalogURL
        self.detailURL = detailURL
        self.sourceID = sourceID
    }
}
