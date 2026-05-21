import Foundation

/// Best-effort cover-image extraction for novel detail pages.
///
/// Used as a fallback in `RuleBasedBookSource.fetchDetail` whenever the
/// rule's `coverField` is nil (the rule author didn't specify a cover
/// selector) or the explicit selector resolved to nothing. The patterns
/// mirror the heuristic browser-import path in `BookImportService`, so
/// JSON-rule imports stop silently dropping covers just because a rule
/// omits one selector that the heuristic path would have inferred.
public enum CoverHeuristics {

    /// Looks for `og:image`, then a series of book-cover-shaped `<img>`
    /// tags — preferring `data-original` over `src` because many CN novel
    /// sites stash the real cover in `data-original` and leave a "no cover"
    /// placeholder in `src`. Result is resolved against `baseURL` and
    /// upgraded to https where applicable (ATS blocks plain http for
    /// AsyncImage even on hosts that serve https).
    public static func extract(fromHTML html: String, baseURL: URL) -> URL? {
        let candidate = metaContent(named: "og:image", in: html)
            ?? firstMatch(#"<img[^>]+(?:id|class)=["'][^"']*(?:cover|bookimg|image|book-img)[^"']*["'][^>]+data-original=["']([^"']+)["']"#, in: html)
            ?? firstMatch(#"<img[^>]+data-original=["']([^"']+)["'][^>]+(?:id|class)=["'][^"']*(?:cover|bookimg|image|book-img)[^"']*["']"#, in: html)
            ?? firstMatch(#"<div[^>]+class=["'][^"']*book-img[^"']*["'][^>]*>\s*<img[^>]+data-original=["']([^"']+)["']"#, in: html)
            ?? firstMatch(#"<div[^>]+class=["'][^"']*book-img[^"']*["'][^>]*>\s*<img[^>]+src=["']([^"']+)["']"#, in: html)
            ?? firstMatch(#"<img[^>]+(?:id|class)=["'][^"']*(?:cover|bookimg|image)[^"']*["'][^>]+src=["']([^"']+)["']"#, in: html)
            ?? firstMatch(#"<img[^>]+src=["']([^"']+)["'][^>]+(?:id|class)=["'][^"']*(?:cover|bookimg|image)[^"']*["']"#, in: html)

        return candidate.flatMap { resolve($0, against: baseURL) }
    }

    /// Plain-http URLs are rejected by App Transport Security for
    /// URLSession/AsyncImage even when the WKWebView reader is allowed via
    /// NSAllowsArbitraryLoadsInWebContent. Some CN novel sites advertise
    /// covers as http even though the same host serves https — upgrade.
    public static func httpsUpgraded(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.scheme = "https"
        return components.url ?? url
    }

    // MARK: -

    private static func resolve(_ href: String, against baseURL: URL) -> URL? {
        let trimmed = decodeEntities(href).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("#"),
              !trimmed.lowercased().hasPrefix("javascript:")
        else { return nil }
        guard let resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
        else { return nil }
        return httpsUpgraded(resolved)
    }

    private static func metaContent(named name: String, in html: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        return firstMatch(#"<meta[^>]+(?:property|name)\s*=\s*["']\#(escaped)["'][^>]+content\s*=\s*["']([^"']*)["'][^>]*>"#, in: html)
            ?? firstMatch(#"<meta[^>]+content\s*=\s*["']([^"']*)["'][^>]+(?:property|name)\s*=\s*["']\#(escaped)["'][^>]*>"#, in: html)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let capture = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[capture])
    }

    /// URL hrefs occasionally arrive HTML-encoded (`&amp;` between query
    /// params). A full entity decoder is heavier than we need; just unwind
    /// the one that matters in practice.
    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
    }
}
