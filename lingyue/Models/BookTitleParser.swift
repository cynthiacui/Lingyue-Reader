import Foundation

/// A scraped book title separated into its semantic parts. Sources routinely glue
/// metadata onto the name they return for a search hit or a detail page —
/// `书名_作者名【完结】`, `《书名》最新章节`, `书名(全本)` — and every consumer
/// (result grouping, tiles, the saved Library record) wants the parts, not the glob.
struct ParsedBookTitle: Equatable {
    /// The bare book name with author / status / site decorations removed.
    let title: String
    /// Author name recovered from the decorations, when one was embedded in the title.
    let author: String?
}

/// Splits scraped titles into book name + author and drops status/site decorations.
/// Shared by Discovery search (tile display and cross-source grouping) and the import
/// pipeline (what gets persisted to the Library), so the two can never drift: a book
/// saved from any source carries the same clean name its search tile showed.
///
/// The parser is deliberately conservative: it only removes a fragment when the
/// fragment is confidently *not* part of a book name (a bracketed status tag, a
/// hard-separator tail that looks like an author or a site brand). Anything
/// ambiguous — paren subtitles like 鬼吹灯(精绝古城), fanfic-universe prefixes like
/// 【综漫】, glued sequel names — survives untouched.
enum BookTitleParser {

    static func parse(_ rawTitle: String, knownAuthor: String? = nil) -> ParsedBookTitle {
        let original = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return ParsedBookTitle(title: "", author: nil) }

        var working = original
        var author: String?

        // 1. A leading 《…》 quote is authoritative: the quoted run is the book name,
        //    provided everything after it reads as decoration (often the author:
        //    《赤心巡天》情何以甚). A tail that could be part of the name keeps the
        //    string whole.
        if working.hasPrefix("《"), let closeRange = working.range(of: "》") {
            let inner = tidied(String(working[working.index(after: working.startIndex)..<closeRange.lowerBound]))
            let tail = String(working[closeRange.upperBound...])
            if !inner.isEmpty {
                let analysis = decorationTailAnalysis(tail, knownAuthor: knownAuthor)
                if analysis.isDecoration {
                    working = inner
                    author = analysis.author
                }
            }
        }

        // 2. Bracketed status tags (【完结】, (全本), …) are metadata wherever they
        //    appear. Brackets whose contents are part of the real name (【综漫】,
        //    【HP】) survive — only the known metadata phrases are stripped.
        working = removingBracketedMetadata(from: working)

        // 3. An explicit 作者 marker is unambiguous: `书名 作者：忘语`.
        if let split = splitExplicitAuthorMarker(working) {
            working = split.head
            if author == nil { author = split.author }
        }

        // 4. A known author from the same scrape outranks any heuristic: strip
        //    `…_忘语`, `… - 忘语`, `…(忘语)`, `…忘语著` tails naming that author.
        if let known = normalizedAuthor(knownAuthor),
           let stripped = strippingKnownAuthorTail(from: working, author: known) {
            working = stripped
            if author == nil { author = known }
        }

        // 5. Hard-separator tail walk: segments after `_` / `|` / `｜` are site junk
        //    or an author name in this corpus, never part of the book name. ` - `
        //    tails are ambiguous (could be a subtitle) and only drop as site junk.
        let walked = strippingSeparatorTails(from: working, author: author)
        working = walked.title
        author = walked.author

        // 6. Reading-page decorations glued straight onto the name (`书名最新章节`).
        working = removingJunkFragments(from: working)
        working = tidied(working)

        guard !working.isEmpty else {
            // Decoration stripping ate the whole string — the "title" was likely pure
            // junk or pure author. Surface the original rather than an empty name.
            return ParsedBookTitle(title: original, author: nil)
        }

        if author == working { author = nil }
        return ParsedBookTitle(title: working, author: author)
    }

    // MARK: - Bracketed metadata

    /// Site-added tags that mark status/format/editorial notes rather than naming the
    /// book. Matched only inside brackets or as a complete separator-tail segment.
    private static let metadataPhrases: [String] = [
        "完本", "完結", "完结", "已完", "已完結", "已完结", "已完成", "完结版", "完結版",
        "連載", "连载", "連載中", "连载中", "斷更", "断更", "全本", "完", "全文完",
        "TXT", "txt", "Txt", "VIP", "vip", "Vip",
        "限免", "免费", "免費", "有声", "有聲",
        "官方", "官方版", "转载", "轉載", "重发", "重發", "重置",
        "推荐", "推薦", "精校", "精校版", "校对", "校對", "原创", "原創",
        "最新章节", "最新章節", "最新", "新书", "新書",
        "已审核", "已審核", "更新", "已更", "完整版", "全文", "番外"
    ]

    /// Connectors sites use to join several tags into one bracket (【完结+番外】,
    /// 【已完结/精校】). Also used to split bare tail segments like `_完结+番外`.
    private static let metadataConnectors = #"[+＋/、,，&·\s]"#

    private static let bracketedMetadataRegex: NSRegularExpression? = {
        // Longest-first keeps prefix phrases (完 / 完结 / 完结版) from shadowing
        // each other inside the alternation.
        let alternation = metadataPhrases
            .sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        let phrase = "(?:" + alternation + ")"
        return try? NSRegularExpression(
            pattern: #"[【\[（(]\s*"# + phrase
                + #"(?:\s*"# + metadataConnectors + #"+\s*"# + phrase + #")*\s*[】\]）)]"#
        )
    }()

    private static func removingBracketedMetadata(from title: String) -> String {
        guard let regex = bracketedMetadataRegex else { return title }
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        return regex.stringByReplacingMatches(in: title, range: range, withTemplate: "")
    }

    // MARK: - Junk fragments

    /// Reading-page decorations sites append to the book name. Stripped repeatedly
    /// from the tail only — a mid-string hit could be a coincidence inside a real
    /// name (e.g. a book whose name contains 小说), a trailing one cannot.
    private static let junkFragments: [String] = [
        "最新章节列表", "最新章節列表", "最新章节目录", "最新章節目錄",
        "最新章节", "最新章節", "章节列表", "章節列表", "章节目录", "章節目錄",
        "全文免费阅读", "全文免費閱讀", "免费在线阅读", "免費在線閱讀",
        "全文阅读", "全文閱讀", "免费阅读", "免費閱讀", "在线阅读", "在線閱讀",
        "无弹窗广告", "無彈窗廣告", "无弹窗", "無彈窗",
        "txt全集下载", "txt下载", "TXT下载", "手机阅读", "手機閱讀", "手机版", "手機版",
        "小说网", "小說網", "小说", "小說", "最新更新", "全集"
    ].sorted { $0.count > $1.count }

    private static func removingJunkFragments(from title: String) -> String {
        var working = tidied(title)
        var changed = true
        while changed {
            changed = false
            for fragment in junkFragments where working.hasSuffix(fragment) && working.count > fragment.count {
                working = tidied(String(working.dropLast(fragment.count)))
                changed = true
            }
        }
        return working
    }

    // MARK: - Author extraction

    private static func normalizedAuthor(_ author: String?) -> String? {
        guard let trimmed = author?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// `书名 作者：忘语` → (书名, 忘语). Only splits when both sides survive.
    private static func splitExplicitAuthorMarker(_ title: String) -> (head: String, author: String)? {
        guard let markerRange = title.range(of: #"作者\s*[:：]"#, options: .regularExpression) else {
            return nil
        }
        let head = tidied(String(title[..<markerRange.lowerBound]))
        let tail = tidied(String(title[markerRange.upperBound...]))
        guard head.count >= 2, let author = authorName(from: firstSegment(of: tail)) else {
            return nil
        }
        return (head, author)
    }

    private static func strippingKnownAuthorTail(from title: String, author: String) -> String? {
        guard title != author else { return nil }
        for (open, close) in [("（", "）"), ("(", ")"), ("【", "】"), ("[", "]")] {
            let suffix = "\(open)\(author)\(close)"
            if title.hasSuffix(suffix) {
                let head = tidied(String(title.dropLast(suffix.count)))
                if !head.isEmpty { return head }
            }
        }
        for separator in ["_", "|", "｜", " - ", "-", "—", "：", ":", " "] {
            let suffix = "\(separator)\(author)"
            if title.hasSuffix(suffix), title.count > suffix.count {
                let head = tidied(String(title.dropLast(suffix.count)))
                if !head.isEmpty { return head }
            }
        }
        let attributed = "\(author)著"
        if title.hasSuffix(attributed), title.count > attributed.count {
            let head = tidied(String(title.dropLast(attributed.count)))
            if !head.isEmpty { return head }
        }
        return nil
    }

    /// Accepts a fragment as a plausible author name: 2–7 Hanzi (covers pen names
    /// like 忘语 and 会说话的肘子), or a short ASCII word run. A trailing 著 both
    /// confirms the guess and gets removed.
    private static func authorName(from candidate: String) -> String? {
        var name = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasSuffix("著"), name.count > 2 {
            name = String(name.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard name.count >= 2, !isSiteNameLike(name) else { return nil }
        if name.range(of: #"^[一-鿿]{2,7}$"#, options: .regularExpression) != nil {
            return name
        }
        if name.range(of: #"^[A-Za-z][A-Za-z0-9 ._·-]{1,19}$"#, options: .regularExpression) != nil {
            return name
        }
        return nil
    }

    // MARK: - Separator tails

    private struct TailSeparator {
        let token: String
        let allowsAuthor: Bool
    }

    private static let tailSeparators: [TailSeparator] = [
        TailSeparator(token: "_", allowsAuthor: true),
        TailSeparator(token: "｜", allowsAuthor: true),
        TailSeparator(token: "|", allowsAuthor: true),
        TailSeparator(token: " - ", allowsAuthor: false),
        TailSeparator(token: " — ", allowsAuthor: false)
    ]

    private static func strippingSeparatorTails(
        from title: String,
        author: String?
    ) -> (title: String, author: String?) {
        var working = title
        var author = author

        while true {
            var last: (separator: TailSeparator, range: Range<String.Index>)?
            for separator in tailSeparators {
                guard let range = working.range(of: separator.token, options: .backwards) else { continue }
                if last == nil || range.lowerBound > last!.range.lowerBound {
                    last = (separator, range)
                }
            }
            guard let (separator, range) = last else { break }

            let head = tidied(String(working[..<range.lowerBound]))
            guard head.count >= 2 else { break }

            // Classify the raw segment before reducing it: a site brand with junk
            // words inside (`某某小说网`) must drop as junk, not shrink to a
            // residue (`某某`) that reads author-shaped.
            let rawSegment = tidied(String(working[range.upperBound...]))
            if rawSegment.isEmpty || isJunkSegment(rawSegment) {
                working = head
                continue
            }
            let segment = normalizedTailSegment(rawSegment)
            if segment.isEmpty || isJunkSegment(segment) {
                working = head
                continue
            }
            if separator.allowsAuthor, author == nil, let name = authorName(from: segment) {
                author = name
                working = head
                continue
            }
            break
        }
        return (working, author)
    }

    /// Reduce a separator-tail segment to its meaningful residue before classifying
    /// it: bracket tags and junk fragments inside the segment are decoration by
    /// definition there (`_忘语最新章节` → `忘语`).
    private static func normalizedTailSegment(_ segment: String) -> String {
        var working = removingBracketedMetadata(from: segment)
        for fragment in junkFragments {
            working = working.replacingOccurrences(of: fragment, with: "")
        }
        return tidied(working)
    }

    private static func isJunkSegment(_ segment: String) -> Bool {
        if metadataPhrases.contains(segment) { return true }
        if segment.count <= 12 && isSiteNameLike(segment) { return true }
        // Compound status tails (`完结+番外`): junk when every connector-separated
        // piece is itself a known tag or decoration.
        let pieces = segment.components(
            separatedBy: CharacterSet(charactersIn: "+＋/、,，&· \t")
        ).filter { !$0.isEmpty }
        guard pieces.count > 1 else { return false }
        return pieces.allSatisfy { metadataPhrases.contains($0) || junkFragments.contains($0) }
    }

    /// Site brands read as names glued from library-ish words (笔趣阁, 某某小说网…).
    /// Used to keep them out of author attribution and drop them as junk tails.
    private static func isSiteNameLike(_ text: String) -> Bool {
        let markers = [
            "小说", "小說", "文学", "文學", "书城", "書城", "书屋", "書屋",
            "书库", "書庫", "书吧", "書吧", "阁", "閣", "网", "網", "首发", "首發"
        ]
        return markers.contains { text.contains($0) }
    }

    // MARK: - Decoration tails after a 《…》 quote

    private static func decorationTailAnalysis(
        _ tail: String,
        knownAuthor: String?
    ) -> (isDecoration: Bool, author: String?) {
        let raw = tidied(removingBracketedMetadata(from: tail))
        if raw.isEmpty { return (true, nil) }
        if let known = normalizedAuthor(knownAuthor), raw == known || raw == "\(known)著" {
            return (true, known)
        }
        if let markerRange = raw.range(of: #"^作者\s*[:：]"#, options: .regularExpression) {
            let name = authorName(from: tidied(String(raw[markerRange.upperBound...])))
            return name.map { (true, $0) } ?? (false, nil)
        }
        // Site brands classify on the raw tail, before junk words inside them are
        // removed — `某某小说网` must not shrink to an author-shaped `某某`.
        if isJunkSegment(raw) { return (true, nil) }

        var reduced = raw
        for fragment in junkFragments {
            reduced = reduced.replacingOccurrences(of: fragment, with: "")
        }
        reduced = tidied(reduced)
        if reduced.isEmpty { return (true, nil) }
        if let name = authorName(from: reduced) { return (true, name) }
        return (false, nil)
    }

    // MARK: - Shared tidy-up

    private static func firstSegment(of text: String) -> String {
        let separators = CharacterSet(charactersIn: "_|｜ \t")
        return text
            .components(separatedBy: separators)
            .first { !$0.isEmpty } ?? text
    }

    /// Removes empty bracket pairs left behind by metadata strips and dangling
    /// separator punctuation at either end. Deliberately does NOT trim brackets or
    /// 《》 themselves — an unpaired strip would corrupt legitimate names like
    /// 鬼吹灯(精绝古城).
    private static func tidied(_ title: String) -> String {
        title
            .replacingOccurrences(of: #"[【\[（(]\s*[】\]）)]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^[\s_｜|·•—–\-:：,，、;；~～]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\s_｜|·•—–\-:：,，、;；~～]+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
