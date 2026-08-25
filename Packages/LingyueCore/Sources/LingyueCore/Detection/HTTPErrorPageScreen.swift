import Foundation

/// Screens out `WebPageSnapshot`s that are HTTP error pages before any
/// source's `detectBook(in:)` gets to claim them.
///
/// Why this exists: an error response keeps the *book's* URL — nginx
/// serving a 502 for `/book/93650/` still matches every host+path
/// detection rule, and the only "title" on the page is the error banner.
/// Reproduced on 大尾笔趣阁 (www.daweixs.com): a mirror outage produced
/// the import prompt 「从 大尾笔趣阁 导入《502 Bad Gateway》」. WKWebView
/// renders historically carried no status code, so the engine parsed
/// whatever HTML the server sent.
///
/// Two independent signals, either one rejects:
/// 1. A known HTTP status code ≥ 400 (the in-app browser forwards the
///    main-frame response status into the snapshot).
/// 2. The content is an obvious stock error page — `<title>` or first
///    `<h1>` carrying a 4xx/5xx status line ("502 Bad Gateway",
///    "HTTP Status 404", Cloudflare's "host | 502: Bad gateway"), a bare
///    English reason phrase, or a tiny body whose only structure is the
///    nginx/openresty `<hr><center>server</center>` footer.
///
/// Deliberately conservative: every content pattern anchors on a Latin
/// status line, so legitimate titles like 「第502章」, 「502教室」, or
/// 「404不存在的国度」 can never match.
public enum HTTPErrorPageScreen {

    public static func isObviousErrorPage(_ snapshot: WebPageSnapshot) -> Bool {
        if let status = snapshot.statusCode, status >= 400 {
            return true
        }
        return isObviousErrorHTML(snapshot.html)
    }

    // MARK: - Content heuristics

    private static func isObviousErrorHTML(_ html: String) -> Bool {
        if let title = firstTagText(titleExtractor, in: html), isErrorStatusLine(title) {
            return true
        }
        if let heading = firstTagText(headingExtractor, in: html), isErrorStatusLine(heading) {
            return true
        }
        // Stock nginx/openresty error pages keep the server-signature
        // footer even when the title got customized. Real book pages are
        // tens of KB; the stock pages are a few hundred bytes, so the
        // size gate alone rules out an article that merely mentions nginx.
        if html.utf8.count < 4096, matches(serverFooterPattern, in: html) {
            return true
        }
        return false
    }

    private static func isErrorStatusLine(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return errorLinePatterns.contains { matches($0, in: text) }
    }

    private static let errorLinePatterns: [NSRegularExpression] = [
        // "502 Bad Gateway", "404 Not Found", "503 Service Temporarily
        // Unavailable" — a 4xx/5xx code followed by a Latin reason phrase.
        // Requiring the Latin letter keeps 「502教室」-style titles safe.
        #"^[45]\d{2}\s+[a-z]"#,
        // "HTTP Status 404 – Not Found" (Tomcat), "Error 521" / "HTTP
        // ERROR 502" (Cloudflare, Chrome's inline error document).
        #"^(http\s+)?(status|error)\s*[:：]?\s*[45]\d{2}\b"#,
        // Cloudflare interstitials: "www.daweixs.com | 502: Bad gateway".
        #"\b[45]\d{2}\s*:\s*[a-z]"#,
        // Reason phrase alone — some servers drop the numeric code. Only
        // phrases that are unambiguous server-speak; "not found" or
        // "forbidden" alone could be a legitimate (English) book title.
        #"^(bad gateway|service (temporarily )?unavailable|gateway time-?out|internal server error|too many requests|request time-?out|origin is unreachable|web server is down|connection timed out|ssl handshake failed)[.!]?$"#,
        // A fresh default vhost answering in place of the mirror.
        #"^welcome to (nginx|openresty|tengine)!?$"#
    ].compactMap { pattern in
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let serverFooterPattern = try? NSRegularExpression(
        pattern: #"<hr\s*/?>\s*<center>\s*(nginx|openresty|tengine|cloudflare)"#,
        options: [.caseInsensitive]
    )

    // MARK: - Lightweight extraction

    // Regex extraction instead of a SelectorEngine parse: this runs on
    // every browser page inspection (3× per load) ahead of the fan-out,
    // and only ever needs the first <title>/<h1>.
    private static let titleExtractor = try? NSRegularExpression(
        pattern: #"<title[^>]*>(.*?)</title>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    private static let headingExtractor = try? NSRegularExpression(
        pattern: #"<h1[^>]*>(.*?)</h1>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    private static func firstTagText(_ extractor: NSRegularExpression?, in html: String) -> String? {
        guard let extractor else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard
            let match = extractor.firstMatch(in: html, options: [], range: range),
            match.numberOfRanges > 1,
            let captured = Range(match.range(at: 1), in: html)
        else { return nil }
        let text = String(html[captured])
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func matches(_ regex: NSRegularExpression?, in text: String) -> Bool {
        guard let regex else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}
