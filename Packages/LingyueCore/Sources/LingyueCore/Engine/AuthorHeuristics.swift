import Foundation

/// Best-effort author extraction for novel detail pages.
///
/// Used as a fallback in `RuleBasedBookSource.fetchDetail` whenever the
/// rule's `authorField` is nil or its selector resolved to nothing. Most
/// seeded JSON rules historically only declare `authorField` on the
/// search step, so the App Store import flow (rule path only) was
/// silently dropping authors that the heuristic browser-import path
/// would have recovered. Patterns mirror `BookImportService.parseMetadata`
/// but with broader separator coverage — Chinese novel sites use
/// `：` / `:` / `︰` (presentation-form), and some sites wrap the label
/// in brackets like `【作 者】<a>name</a>` with no colon at all.
public enum AuthorHeuristics {

    /// Tries meta tags, JS literals, then `作者` label patterns. The
    /// returned string has HTML tags stripped and whitespace collapsed.
    public static func extract(fromHTML html: String) -> String? {
        let raw = metaContent(named: "og:novel:author", in: html)
            ?? metaContent(named: "author", in: html)
            ?? firstMatch(#"author\s*:\s*['"]([^'"]+)['"]"#, in: html)
            ?? firstMatch(#"作\s*者(?:[】\]》〕]\s*|\s*[：:︰]\s*)<a[^>]*>([^<]{1,60})</a>"#, in: html)
            ?? firstMatch(#"作\s*者(?:[】\]》〕]\s*|\s*[：:︰]\s*)</span>\s*<[^>]+>([^<]{1,60})</"#, in: html)
            ?? firstMatch(#"作\s*者(?:[】\]》〕]\s*|\s*[：:︰]\s*)([^<\n\r]{1,40})"#, in: html)
        guard let raw else { return nil }
        let cleaned = clean(raw)
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: -

    /// Strips HTML tags, decodes the handful of entities we see in
    /// practice (`&amp;`, numeric entities are rare in author fields),
    /// and collapses whitespace. Matches `BookImportService.cleanText`
    /// closely enough for author names.
    private static func clean(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
}
