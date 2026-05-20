import Foundation
import SwiftSoup

public extension SourceRule {
    /// Scan a homepage snapshot for the first internal anchor whose path
    /// matches `detection.pathPattern`. Auto-verification falls back to
    /// this when the rule has no `search` step (jsonAPI or
    /// browser-import-only rules) so the catalog/chapter chain still has
    /// a real detail URL to walk. Returns nil when the rule has no path
    /// pattern, the parse fails, or no anchor matches.
    func firstDetailURL(in snapshot: WebPageSnapshot) -> URL? {
        detailURLs(in: snapshot, limit: 1).first
    }

    /// All internal anchors whose path matches `detection.pathPattern`,
    /// in document order, deduplicated, capped at `limit`. Some sites
    /// poison the first few links (404 stubs, removed books); auto-verify
    /// walks this list rather than just taking `firstDetailURL`.
    func detailURLs(in snapshot: WebPageSnapshot, limit: Int) -> [URL] {
        guard limit > 0,
              let pattern = detection.pathPattern,
              let regex = try? NSRegularExpression(pattern: pattern)
        else { return [] }
        guard let document = try? SwiftSoup.parse(snapshot.html, snapshot.finalURL.absoluteString) else {
            return []
        }
        let anchors: Elements
        do {
            anchors = try document.select("a[href]")
        } catch {
            return []
        }
        let baseHost = snapshot.finalURL.host(percentEncoded: false)?.lowercased() ?? ""
        var results: [URL] = []
        var seen: Set<URL> = []
        for anchor in anchors {
            guard
                let href = try? anchor.attr("href"),
                !href.isEmpty,
                let resolved = URL(string: href, relativeTo: snapshot.finalURL)?.absoluteURL
            else { continue }
            let anchorHost = resolved.host(percentEncoded: false)?.lowercased() ?? ""
            if !anchorHost.isEmpty && !baseHost.isEmpty
                && anchorHost != baseHost
                && !anchorHost.hasSuffix("." + baseHost)
                && !baseHost.hasSuffix("." + anchorHost) {
                continue
            }
            let path = resolved.path.isEmpty ? "/" : resolved.path
            let range = NSRange(path.startIndex..., in: path)
            guard regex.firstMatch(in: path, options: [], range: range) != nil else { continue }
            if seen.insert(resolved).inserted {
                results.append(resolved)
                if results.count >= limit { break }
            }
        }
        return results
    }
}
