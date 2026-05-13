import Foundation

/// One entry in a book's chapter list. The catalog page yields an array of
/// these; the reader caches the array and resolves bodies on demand by
/// calling `BookSource.fetchChapter(url:)` with `url`.
public struct ChapterLink: Sendable, Hashable, Codable {
    /// Chapter title, as the source shows it. Engine has applied any
    /// configured transforms.
    public var title: String

    /// Absolute URL of the chapter page. Engine has resolved it from the
    /// catalog page's base.
    public var url: URL

    /// Volume / section grouping label, when the catalog exposes one.
    /// Common on long web-novels organized into 卷 / 部.
    public var volume: String?

    /// 0-based index within the full chapter list. Useful for resuming a
    /// reader position by index when URLs change format across catalog
    /// pagination.
    public var index: Int

    public init(
        title: String,
        url: URL,
        volume: String? = nil,
        index: Int
    ) {
        self.title = title
        self.url = url
        self.volume = volume
        self.index = index
    }
}
