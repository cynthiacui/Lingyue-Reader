import Foundation

/// The body of one chapter, post-extraction. What the reader pagination
/// engine consumes. The rule has already stripped chrome, decoded
/// entities, and converted `<br>` to newlines per the source's transforms.
public struct ChapterContent: Sendable, Hashable, Codable {
    /// Chapter title as the chapter page presents it. May differ from the
    /// catalog's title (some sources truncate or volume-prefix). The
    /// reader prefers this when present.
    public var title: String

    /// Plain-text body, paragraph-separated by `\n\n`. The reader's
    /// pagination engine splits on this; no further HTML interpretation
    /// happens downstream.
    public var paragraphs: [String]

    /// Optional URL to the next chapter, if the chapter page exposed one.
    /// Saves a catalog round-trip when the reader scrolls past the end.
    public var nextChapterURL: URL?

    /// Optional URL to the previous chapter, mirror of `nextChapterURL`.
    public var previousChapterURL: URL?

    public init(
        title: String,
        paragraphs: [String],
        nextChapterURL: URL? = nil,
        previousChapterURL: URL? = nil
    ) {
        self.title = title
        self.paragraphs = paragraphs
        self.nextChapterURL = nextChapterURL
        self.previousChapterURL = previousChapterURL
    }
}
