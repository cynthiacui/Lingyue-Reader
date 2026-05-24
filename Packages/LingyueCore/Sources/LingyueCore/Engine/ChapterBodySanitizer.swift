import Foundation

/// Cleans up paragraphs returned by either `RuleBasedBookSource`'s HTML
/// path or `JSONAPIBookSource`'s decode path. Centralizes the strimming
/// that the old per-source hardcoded parsers used to do ad-hoc:
///
/// 1. Leading **title echoes** — Chinese book sites routinely repeat the
///    chapter title inside the body container (sometimes verbatim,
///    sometimes with a `(1/2)` pagination suffix, sometimes as a generic
///    `第N章 …` heading even when the rule's `titleField` already
///    captured it).
/// 2. **Author bylines** — `作者：XXX` lines that some sites stamp into
///    every chapter body.
/// 3. **Pagination markers** — bare `(1/2)` style page indicators.
/// 4. **Boilerplate fragments** — "请收藏本站", "上一章 下一章" footer
///    text that survives `stripHTML` because it's plain text inside the
///    body div.
///
/// Universal across sources by design — rule authors should never have
/// to re-encode the same junk list per site. New patterns added here
/// take effect everywhere.
public enum ChapterBodySanitizer {

    /// Drop leading title echoes / bylines, drop pagination markers, drop
    /// well-known boilerplate fragments anywhere in the body. Returns a
    /// new array; never mutates the input.
    public static func sanitize(paragraphs: [String], title: String?) -> [String] {
        guard !paragraphs.isEmpty else { return paragraphs }

        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let titleVariants = makeTitleVariants(normalizedTitle)

        // Strip leading lines that echo the title or otherwise look like
        // a header — capped at the first few paragraphs so a chapter
        // whose *content* happens to start with "第" doesn't get eaten.
        var working = paragraphs
        let headerWindow = min(4, working.count)
        var consumed = 0
        while consumed < headerWindow {
            let line = working[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                working.removeFirst()
                consumed += 1
                continue
            }
            if isLeadingHeaderLine(line, titleVariants: titleVariants) {
                working.removeFirst()
                consumed += 1
                continue
            }
            break
        }

        // Universal per-line filter. Walks every paragraph (not just the
        // header) — pagination markers and boilerplate footers tend to
        // sit at the end of the body. Short lines only (≤80 chars) so
        // real prose doesn't get tripped by an unfortunate substring.
        let cleaned = working.compactMap { paragraph -> String? in
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            if Self.isPaginationMarker(trimmed) { return nil }
            if Self.isAuthorByline(trimmed) { return nil }
            if Self.isBoilerplate(trimmed) { return nil }
            return trimmed
        }
        return cleaned
    }

    // MARK: - Header detection

    /// True when `line` looks like a leading header rather than prose.
    /// Generous on the first paragraph (matches title echoes, generic
    /// `第N章` headings, author bylines) — the caller caps how many
    /// header lines we'll strip so a real chapter that opens with a
    /// header-shaped sentence isn't truncated.
    private static func isLeadingHeaderLine(
        _ line: String,
        titleVariants: Set<String>
    ) -> Bool {
        if titleVariants.contains(line) { return true }
        // Title plus a pagination suffix, e.g. "第51章 暗杀！(1/2)".
        if let stripped = stripTrailingPagination(line), titleVariants.contains(stripped) {
            return true
        }
        // Generic chapter heading: "第N章 …" / "第N节 …" / "第N回 …".
        // Bounded length so a sentence that happens to contain "第" mid-prose
        // can't masquerade as a header.
        if line.count <= 60, looksLikeGenericChapterHeading(line) {
            return true
        }
        if isAuthorByline(line) { return true }
        // Leading "<book title> 作者：<name>" — some site templates
        // stamp this into the body even when the rule's bodyField
        // doesn't capture the surrounding metadata block.
        // Strict on length so a single mid-prose mention of an author
        // can't be dropped by mistake.
        if line.count <= 80, containsAuthorByline(line) {
            return true
        }
        if isPaginationMarker(line) { return true }
        return false
    }

    /// True when `line` contains a `作者：XXX` byline anywhere — used
    /// only for leading-line detection where the byline may sit after
    /// a book-title prefix (a typical `<p>书名… 作者：作者名</p>` shape).
    private static func containsAuthorByline(_ line: String) -> Bool {
        let pattern = #"作\s*者\s*[：:]\s*\S"#
        return line.range(of: pattern, options: .regularExpression) != nil
    }

    /// Build the set of strings considered "the same title" — handles
    /// 全角/半角 punctuation variance and the common case of a title
    /// containing trailing pagination like "(1/2)".
    private static func makeTitleVariants(_ title: String) -> Set<String> {
        guard !title.isEmpty else { return [] }
        var variants: Set<String> = [title]
        let collapsed = title
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !collapsed.isEmpty { variants.insert(collapsed) }
        if let stripped = stripTrailingPagination(title) { variants.insert(stripped) }
        return variants
    }

    /// Pulls a trailing `(1/2)` / `（1/2）` page marker off the end of
    /// `line` and returns the remainder, trimmed. Returns nil when no
    /// marker is present.
    private static func stripTrailingPagination(_ line: String) -> String? {
        let pattern = #"\s*[（(]\s*\d+\s*/\s*\d+\s*[）)]\s*$"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern, options: []),
            let match = regex.firstMatch(
                in: line,
                options: [],
                range: NSRange(line.startIndex..., in: line)
            ),
            let range = Range(match.range, in: line)
        else { return nil }
        let trimmed = String(line[line.startIndex..<range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func looksLikeGenericChapterHeading(_ line: String) -> Bool {
        // "第" + (digits | Chinese numerals) + (章|节|節|回|卷|话|話|篇)
        // optionally followed by chapter-name text. Short cap above; this
        // regex itself is intentionally permissive about what follows the
        // chapter unit so per-site variations (titled chapters, anchor
        // glyphs) still match.
        let pattern = #"^\s*第[\d零〇一二三四五六七八九十百千万两壹貳贰叁參参肆伍陸陆柒捌玖拾佰仟]+[章节節回卷话話篇]"#
        return line.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - Per-line filters

    /// "(1/2)" / "（1/2）" / "1/2" sitting alone on a paragraph.
    private static func isPaginationMarker(_ line: String) -> Bool {
        let pattern = #"^\s*[（(]?\s*\d+\s*/\s*\d+\s*[）)]?\s*$"#
        return line.range(of: pattern, options: .regularExpression) != nil
    }

    /// "作者：XXX" / "作者: XXX" / "作\u{3000}者 : XXX" — short lines
    /// only so a paragraph that mentions an author inside prose doesn't
    /// get nuked.
    private static func isAuthorByline(_ line: String) -> Bool {
        guard line.count <= 40 else { return false }
        let pattern = #"^\s*作\s*者\s*[：:]\s*\S"#
        return line.range(of: pattern, options: .regularExpression) != nil
    }

    /// Universal boilerplate substring match. Length-capped so a long
    /// paragraph that happens to contain "上一章" mid-sentence can't be
    /// dropped.
    private static func isBoilerplate(_ line: String) -> Bool {
        guard line.count <= 60 else { return false }
        return boilerplateFragments.contains { line.localizedCaseInsensitiveContains($0) }
    }

    private static let boilerplateFragments: [String] = [
        // Bookmark / save-this-site footers.
        "请收藏本站", "請收藏本站", "加入书签", "加入書簽",
        // Navigation.
        "返回目录", "返回目錄", "返回书架", "返回書架",
        "上一章", "下一章", "上一页", "上一頁", "下一页", "下一頁",
        "最新网址", "最新網址", "手机用户", "手機用戶",
        // Continued-chapter / report-error markers.
        "本章未完", "点击报错", "點擊報錯", "继续阅读", "繼續閱讀",
        // Mirror-promo lines.
        "天才一秒记住", "天才一秒鐘記住",
        "无弹窗", "無彈窗",
        "看本书最新章节", "看本書最新章節",
        // Font / display controls leaked into body text.
        "字体大小", "字體大小"
    ]
}
