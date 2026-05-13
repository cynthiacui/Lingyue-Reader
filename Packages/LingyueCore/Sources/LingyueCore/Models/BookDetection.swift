import Foundation

/// Result of running `BookSource.detectBook(in:)` against a
/// `WebPageSnapshot`. Returned by sources that recognize a page as one of
/// their book-detail pages; `nil` from `detectBook` means "not mine".
///
/// The in-app browser fans every page-load out across enabled sources and
/// uses the first non-nil detection to surface the Import button. We
/// carry a confidence score so two sources both claiming the page can be
/// resolved deterministically (highest confidence wins, ties broken by
/// the registry's priority order).
public struct BookDetection: Sendable, Hashable, Codable {
    /// 0.0–1.0. A weak host-name-only match is ~0.4; a host match plus a
    /// known catalog selector finding chapters is ~0.9. The browser uses
    /// this for tiebreaking, not for thresholding — the source already
    /// decided it's a match when it returned non-nil.
    public var confidence: Double

    /// The canonical detail URL for this book, if the rule can derive it
    /// from the page. Often equals `snapshot.finalURL` but rules can
    /// rewrite tracking-laden URLs to a clean form before import.
    public var detailURL: URL

    /// Optional pre-extracted title shown next to the Import button.
    /// Source-as-shown after transforms.
    public var title: String?

    /// Stable namespaced source ID — the source that produced the
    /// detection. Lets the browser show "Import from 〈source name〉" with
    /// authoritative attribution.
    public var sourceID: String

    public init(
        confidence: Double,
        detailURL: URL,
        title: String? = nil,
        sourceID: String
    ) {
        self.confidence = confidence
        self.detailURL = detailURL
        self.title = title
        self.sourceID = sourceID
    }
}
