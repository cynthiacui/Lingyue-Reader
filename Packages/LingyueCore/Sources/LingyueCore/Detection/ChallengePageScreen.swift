import Foundation

/// Recognizes anti-bot interstitials (Cloudflare's "Just a moment…" /
/// 「请稍候…」 pages) so the headless renderer can keep waiting for the
/// real page instead of handing challenge HTML to the parse pipeline.
///
/// Why this exists: sources marked `requiresWebRender` sit behind
/// Cloudflare. A cold render (no `cf_clearance` cookie yet) finishes its
/// *first* navigation on the challenge page itself — the interstitial then
/// swaps to the real page several seconds later via its own navigation.
/// A renderer that snapshots after the first navigation returns challenge
/// HTML: zero search rows, "empty" catalogs, phantom detection failures.
/// Reproduced on 半夏小说 (xbanxia.cc): the challenge cleared at ~7s while
/// the render timeout was 6s, so every cold search parsed the interstitial.
///
/// Deliberately conservative — a false positive would make the renderer
/// burn its full challenge grace on a legitimate page:
/// 1. `_cf_chl` only ever appears in the challenge interstitial's own
///    script/form plumbing (`window._cf_chl_opt`, `__cf_chl_rt_tk` form
///    tokens). The *invisible* bot-management beacon that CF injects into
///    ordinary proxied pages uses different symbols (`__CF$cv$params`,
///    `/cdn-cgi/challenge-platform/` script paths), so normal pages on
///    CF-fronted sites never match.
/// 2. Title patterns anchor on the exact stock interstitial titles, and
///    only on the `<title>` tag — a chapter body that merely *mentions*
///    「请稍候」 can never match.
public enum ChallengePageScreen {

    public static func isChallenge(_ html: String) -> Bool {
        if html.contains("_cf_chl") {
            return true
        }
        if let title = pageTitle(in: html), isChallengeTitle(title) {
            return true
        }
        return false
    }

    private static func isChallengeTitle(_ title: String) -> Bool {
        challengeTitlePatterns.contains { regex in
            let range = NSRange(title.startIndex..., in: title)
            return regex.firstMatch(in: title, options: [], range: range) != nil
        }
    }

    private static let challengeTitlePatterns: [NSRegularExpression] = [
        // Cloudflare interactive/managed challenge, EN + zh variants.
        #"^just a moment\.{0,3}…?$"#,
        #"^(请稍候|請稍候)\s*[.…]{0,3}$"#,
        // Cloudflare block/attention page and the legacy JS challenge.
        #"^attention required!\s*\|\s*cloudflare$"#,
        #"^checking your browser\b"#,
        // DDoS-Guard's interstitial.
        #"^ddos-guard$"#
    ].compactMap { pattern in
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    // Same lightweight regex extraction as `HTTPErrorPageScreen` — this
    // runs inside the renderer's poll loop, so a full DOM parse per tick
    // would be pure waste for a first-`<title>` read.
    private static let titleExtractor = try? NSRegularExpression(
        pattern: #"<title[^>]*>(.*?)</title>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    private static func pageTitle(in html: String) -> String? {
        guard let titleExtractor else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard
            let match = titleExtractor.firstMatch(in: html, options: [], range: range),
            match.numberOfRanges > 1,
            let captured = Range(match.range(at: 1), in: html)
        else { return nil }
        let text = String(html[captured])
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
