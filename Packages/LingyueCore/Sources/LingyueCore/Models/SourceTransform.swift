import Foundation

/// Closed set of transforms a rule can chain onto an extracted string.
/// Deliberately enumerated — not free-form code — so a rule can never
/// execute user-supplied logic. Apple App Store review posture rests on
/// this: user rules are pure data; the app interprets them.
public enum SourceTransform: Codable, Sendable, Hashable {
    /// Strip leading/trailing whitespace and collapse interior runs of
    /// whitespace to a single space.
    case trim

    /// Collapse interior whitespace (including non-breaking spaces and
    /// full-width spaces common on Chinese novel sites) without trimming
    /// edges.
    case collapseWhitespace

    /// Resolve a possibly-relative URL against the page's base URL.
    case absoluteURL

    /// Replace every match of `pattern` with `replacement`. Pattern is an
    /// `NSRegularExpression`-compatible string; engine compiles with
    /// case-sensitive + dot-not-newline by default. Invalid patterns turn
    /// into `parseFailed` at apply-time, surfaced through the rule editor.
    case regexReplace(pattern: String, replacement: String)

    /// Keep only the first regex capture group's match. Useful for pulling
    /// a numeric id out of a longer URL path.
    case regexCapture(pattern: String)

    /// Strip HTML tags but keep visible text content. Used by chapter
    /// body extraction when the rule's selector hits a `<div>` containing
    /// `<br>`-joined paragraphs.
    case stripHTML

    /// Replace `<br>` / `<br/>` with newlines before stripping other HTML.
    /// Important for chapter bodies that use `<br>` as paragraph break.
    case brToNewline

    /// Prepend the literal string. Used for hosts that return path-only
    /// hrefs without a leading slash.
    case prefix(String)

    /// Append the literal string.
    case suffix(String)

    /// Decode common HTML entities (`&amp;`, `&lt;`, `&#x...;`, `&#...;`).
    /// SwiftSoup does this on `text()`, so this transform is mainly for
    /// values pulled from attributes via `attr(…)`.
    case decodeHTMLEntities
}
