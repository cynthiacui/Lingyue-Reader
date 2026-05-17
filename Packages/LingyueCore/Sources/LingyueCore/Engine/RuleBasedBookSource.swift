import Foundation
import SwiftSoup

/// `BookSource` driven by a `SourceRule` + a `SourceHTMLLoading`. The
/// engine: builds requests from the rule's templates, dispatches them
/// through the loader (HTTP or render per `EnginePerStep`), parses the
/// returned HTML with `SelectorEngine`, runs the rule's transforms,
/// emits typed values.
///
/// Stateless beyond the rule + loader — all per-call state is local.
/// Sendable because every stored property is.
public struct RuleBasedBookSource: BookSource {
    public let rule: SourceRule
    public let loader: any SourceHTMLLoading

    public init(rule: SourceRule, loader: any SourceHTMLLoading) {
        self.rule = rule
        self.loader = loader
    }

    public var id: String { "rule:\(rule.id.uuidString)" }
    public var displayName: String { rule.name }
    public var capabilities: SourceCapabilities { rule.capabilities }

    // MARK: - Search

    public func search(_ query: String) async throws -> [BookSearchResult] {
        guard let step = rule.search else {
            throw BookSourceError.searchUnsupported
        }
        let snapshot = try await runSearchRequest(step: step, query: query)
        let document = try SelectorEngine.parse(snapshot.html, baseURL: snapshot.finalURL)
        let rows = try SelectorEngine.selectAll(step.resultsSelector, in: document)
        var results: [BookSearchResult] = []
        results.reserveCapacity(rows.size())
        for row in rows {
            // Walk every match for the title selector and pick the first
            // non-empty one — search rows on Chinese book sites commonly
            // have two anchors per result (one wraps an `<img>`, one
            // wraps the visible `<h2>`/text). `resolveSingle` would
            // return the empty img-anchor and the row would silently
            // drop out of the result list with no user-facing hits.
            let titleCandidates = (try? SelectorEngine.resolveAll(
                step.titleField, scope: row, baseURL: snapshot.finalURL
            )) ?? []
            guard
                let title = titleCandidates
                    .lazy
                    .compactMap({ $0.nonEmptyTrimmed })
                    .first,
                let detailURLString = try SelectorEngine.resolveSingle(
                    step.detailURLField, scope: row, baseURL: snapshot.finalURL
                ),
                let detailURL = URL(string: detailURLString)
            else {
                continue
            }
            let author = try step.authorField.flatMap {
                try SelectorEngine.resolveSingle($0, scope: row, baseURL: snapshot.finalURL)
            }
            let cover = try step.coverField.flatMap {
                try SelectorEngine.resolveSingle($0, scope: row, baseURL: snapshot.finalURL)
            }.flatMap(URL.init(string:))
            let snippet = try step.snippetField.flatMap {
                try SelectorEngine.resolveSingle($0, scope: row, baseURL: snapshot.finalURL)
            }
            results.append(BookSearchResult(
                title: title,
                author: author,
                coverURL: cover,
                snippet: snippet,
                detailURL: detailURL,
                sourceID: id
            ))
        }
        return results
    }

    private func runSearchRequest(
        step: SearchStep,
        query: String
    ) async throws -> WebPageSnapshot {
        let queryEncoding = step.queryEncoding ?? .utf8
        let expandedURL = try URLTemplate.expand(
            step.urlTemplate, query: query, encoding: queryEncoding
        )
        guard let url = URL(string: expandedURL) else {
            throw BookSourceError.ruleIncomplete(field: "search.urlTemplate")
        }
        let body: Data?
        var headers = rule.defaultHeaders
        if let bodyTemplate = step.bodyTemplate {
            let expanded = try URLTemplate.expand(
                bodyTemplate, query: query, encoding: queryEncoding
            )
            // The body is already percent-encoded ASCII (form-urlencoded
            // bytes), so UTF-8 vs the rule's charset doesn't matter for the
            // wire bytes themselves — but legacy backends still inspect the
            // Content-Type charset to know how to interpret the
            // percent-decoded bytes. Set it explicitly when the rule asked
            // for a non-UTF-8 query encoding.
            body = expanded.data(using: .utf8)
            if step.method == .post,
               let iana = step.queryEncoding?.ianaName,
               headers["Content-Type"] == nil,
               headers["content-type"] == nil {
                headers["Content-Type"] =
                    "application/x-www-form-urlencoded; charset=\(iana)"
            }
        } else {
            body = nil
        }
        let request = SourceRequest(
            url: url,
            method: step.method == .post ? .post : .get,
            headers: headers,
            body: body,
            encoding: rule.encoding,
            referer: rule.homepage
        )
        return try await load(request, step: .search)
    }

    // MARK: - Detection

    public func detectBook(in page: WebPageSnapshot) async throws -> BookDetection? {
        let det = rule.detection
        guard let host = page.finalURL.host else { return nil }
        guard det.hostPatterns.isEmpty || det.hostPatterns.contains(where: { match(glob: $0, host: host) }) else {
            return nil
        }
        // Safety net for rules authored by the URL Analyzer before it
        // derived a `pathPattern`: with only `hostPatterns` set, every
        // page of the site (including the homepage) matches. Refuse to
        // claim a detection on root-like paths when no path or
        // confirm-selector disambiguator exists. Seeded rules always
        // ship a pathPattern, so this branch only catches the
        // analyzer-built case.
        if det.pathPattern == nil && det.confirmSelector == nil {
            let path = page.finalURL.path
            if path.isEmpty || path == "/" { return nil }
        }
        var confidence = 0.4
        if let pattern = det.pathPattern {
            let path = page.finalURL.path
            let regex = try? NSRegularExpression(pattern: pattern, options: [])
            let range = NSRange(path.startIndex..., in: path)
            guard regex?.firstMatch(in: path, options: [], range: range) != nil else {
                return nil
            }
            confidence += 0.3
        }
        let document = try SelectorEngine.parse(page.html, baseURL: page.finalURL)
        if let confirmSelector = det.confirmSelector {
            let matches = try SelectorEngine.selectAll(confirmSelector, in: document)
            guard !matches.isEmpty() else { return nil }
            confidence += 0.2
        }
        let canonical: URL
        if
            let canonicalField = det.canonicalURL,
            let resolved = try SelectorEngine.resolveSingle(
                canonicalField, scope: document, baseURL: page.finalURL
            ),
            let url = URL(string: resolved)
        {
            canonical = url
            confidence += 0.1
        } else {
            canonical = page.finalURL
        }
        // Resolve detail title, skipping any candidate that echoes the
        // rule's own display name — that's the site logo, not the book
        // title (common when `detail.titleField` is the analyzer's
        // default `h1` and the page header carries the site name in an
        // `<h1>` of its own). Falls back to nil so the browser's
        // page-`<title>` chain takes over.
        let title = try resolveTitleSkippingSiteName(
            scope: document,
            baseURL: page.finalURL
        )
        return BookDetection(
            confidence: min(confidence, 1.0),
            detailURL: canonical,
            title: title,
            sourceID: id
        )
    }

    /// Resolve `rule.detail.titleField` against `scope` and pick the
    /// first candidate that isn't the site name. Walks `resolveAll`
    /// because the analyzer's default `h1` selector commonly matches
    /// both the site-logo `<h1>` and the book-title `<h1>` — the first
    /// element wins under `resolveSingle`, which is exactly the wrong
    /// one on sites whose header is an `<h1>`. Returns nil when every
    /// candidate echoes `rule.name`; callers fall back to the page
    /// `<title>` chain.
    private func resolveTitleSkippingSiteName(
        scope: Element,
        baseURL: URL
    ) throws -> String? {
        let candidates = try SelectorEngine.resolveAll(
            rule.detail.titleField,
            scope: scope,
            baseURL: baseURL
        )
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.caseInsensitiveCompare(rule.name) == .orderedSame { continue }
            return trimmed
        }
        return nil
    }

    private func match(glob: String, host: String) -> Bool {
        // Simple glob: a leading "*." matches any subdomain, else exact host.
        if glob == host { return true }
        if glob.hasPrefix("*.") {
            let suffix = glob.dropFirst(2)
            return host == suffix || host.hasSuffix("." + suffix)
        }
        // `SourceAnalyzer.uniqueHosts` strips `www.` from stored patterns —
        // it treats `www.` as a no-op subdomain. Mirror that here so a
        // pattern like `xbanxia.cc` matches a live page at `www.xbanxia.cc`
        // without forcing the analyzer to author both variants. Seeded
        // rules that list both explicitly still hit the equality branch
        // above, so this is purely additive.
        let strippedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return glob == strippedHost
    }

    // MARK: - Detail

    public func fetchDetail(url: URL) async throws -> BookDetail {
        let request = baseRequest(for: url)
        let snapshot = try await load(request, step: .detail)
        let document = try SelectorEngine.parse(snapshot.html, baseURL: snapshot.finalURL)
        let step = rule.detail

        guard let title = try resolveTitleSkippingSiteName(
            scope: document,
            baseURL: snapshot.finalURL
        ) else {
            throw BookSourceError.parseFailed(field: "detail.titleField")
        }

        guard let catalogURLString = try SelectorEngine.resolveSingle(
            step.catalogURLField, scope: document, baseURL: snapshot.finalURL
        ), let catalogURL = URL(string: catalogURLString) else {
            throw BookSourceError.parseFailed(field: "detail.catalogURLField")
        }

        let author = try step.authorField.flatMap {
            try SelectorEngine.resolveSingle($0, scope: document, baseURL: snapshot.finalURL)
        }
        let coverString = try step.coverField.flatMap {
            try SelectorEngine.resolveSingle($0, scope: document, baseURL: snapshot.finalURL)
        }
        let description = try step.descriptionField.flatMap {
            try SelectorEngine.resolveSingle($0, scope: document, baseURL: snapshot.finalURL)
        }
        let status = try step.statusField.flatMap {
            try SelectorEngine.resolveSingle($0, scope: document, baseURL: snapshot.finalURL)
        }
        let statistics = try step.statisticsField.flatMap {
            try SelectorEngine.resolveSingle($0, scope: document, baseURL: snapshot.finalURL)
        }
        let tags: [String] = try step.tagsField.map {
            try SelectorEngine.resolveAll($0, scope: document, baseURL: snapshot.finalURL)
        } ?? []

        return BookDetail(
            title: title,
            author: author,
            coverURL: coverString.flatMap(URL.init(string:)),
            description: description,
            tags: tags,
            status: status,
            statistics: statistics,
            catalogURL: catalogURL,
            detailURL: url,
            sourceID: id
        )
    }

    // MARK: - Catalog

    public func fetchCatalog(url: URL) async throws -> [ChapterLink] {
        let step = rule.catalog
        var allChapters: [ChapterLink] = []
        var nextURL: URL? = url
        var pagesWalked = 0
        var currentIndex = 0
        var visited: Set<URL> = []

        while let pageURL = nextURL, pagesWalked < step.maxPages {
            if visited.contains(pageURL) { break }
            visited.insert(pageURL)
            pagesWalked += 1

            let snapshot = try await load(baseRequest(for: pageURL), step: .catalog)
            let document = try SelectorEngine.parse(snapshot.html, baseURL: snapshot.finalURL)
            var currentVolume: String? = nil

            // Volume detection works best when chaptersSelector matches a
            // sibling set that may include volume headers. The rule
            // author keeps that selector inclusive; we filter the rows
            // and carry the most recent volume forward.
            let rows = try SelectorEngine.selectAll(step.chaptersSelector, in: document)
            for row in rows {
                if let volumeField = step.volumeField {
                    if let v = try? SelectorEngine.resolveSingle(
                        volumeField, scope: row, baseURL: snapshot.finalURL
                    ), let nonEmpty = v.nonEmptyTrimmed {
                        currentVolume = nonEmpty
                    }
                }
                guard let title = try SelectorEngine.resolveSingle(
                    step.titleField, scope: row, baseURL: snapshot.finalURL
                ), let nonEmpty = title.nonEmptyTrimmed else {
                    continue
                }
                guard let urlString = try SelectorEngine.resolveSingle(
                    step.urlField, scope: row, baseURL: snapshot.finalURL
                ), let chapterURL = URL(string: urlString) else {
                    continue
                }
                // Universal nav-link filter — drops entries that look
                // like site navigation rather than book chapters. Common
                // when the rule's `chaptersSelector` is loose enough to
                // also match a header menu or footer list (e.g.,
                // analyzer picked `ul > li` and the page's only such
                // list is the genre menu).
                if Self.looksLikeNavLink(
                    title: nonEmpty,
                    chapterURL: chapterURL,
                    catalogURL: snapshot.finalURL
                ) {
                    continue
                }
                allChapters.append(ChapterLink(
                    title: nonEmpty,
                    url: chapterURL,
                    volume: currentVolume,
                    index: currentIndex
                ))
                currentIndex += 1
            }

            // Pagination.
            if
                let nextField = step.nextPageField,
                let nextString = try? SelectorEngine.resolveSingle(
                    nextField, scope: document, baseURL: snapshot.finalURL
                ),
                let trimmed = nextString.nonEmptyTrimmed,
                let parsed = URL(string: trimmed)
            {
                nextURL = parsed
            } else {
                nextURL = nil
            }
        }
        return allChapters
    }

    // MARK: - Chapter

    public func fetchChapter(url: URL) async throws -> ChapterContent {
        let step = rule.chapter
        var bodyPieces: [String] = []
        var titleSeed: String? = nil
        var nextLink: URL? = nil
        var prevLink: URL? = nil

        var pageURL: URL? = url
        var pagesWalked = 0
        var visited: Set<URL> = []

        while let current = pageURL, pagesWalked < step.maxBodyPages {
            if visited.contains(current) { break }
            visited.insert(current)
            pagesWalked += 1

            let snapshot = try await load(baseRequest(for: current), step: .chapter)
            let document = try SelectorEngine.parse(snapshot.html, baseURL: snapshot.finalURL)

            if titleSeed == nil {
                titleSeed = try SelectorEngine.resolveSingle(
                    step.titleField, scope: document, baseURL: snapshot.finalURL
                )
            }

            if let bodyText = try SelectorEngine.resolveSingle(
                step.bodyField, scope: document, baseURL: snapshot.finalURL
            ) {
                bodyPieces.append(bodyText)
            }

            // next/prev are read once, off the first page.
            if pagesWalked == 1 {
                if
                    let nf = step.nextChapterField,
                    let s = try? SelectorEngine.resolveSingle(
                        nf, scope: document, baseURL: snapshot.finalURL
                    ),
                    let trimmed = s.nonEmptyTrimmed,
                    let url = URL(string: trimmed)
                {
                    nextLink = url
                }
                if
                    let pf = step.previousChapterField,
                    let s = try? SelectorEngine.resolveSingle(
                        pf, scope: document, baseURL: snapshot.finalURL
                    ),
                    let trimmed = s.nonEmptyTrimmed,
                    let url = URL(string: trimmed)
                {
                    prevLink = url
                }
            }

            // Body-pagination follow.
            if
                let nbpf = step.nextBodyPageField,
                let s = try? SelectorEngine.resolveSingle(
                    nbpf, scope: document, baseURL: snapshot.finalURL
                ),
                let trimmed = s.nonEmptyTrimmed,
                let url = URL(string: trimmed)
            {
                pageURL = url
            } else {
                pageURL = nil
            }
        }

        let joined = bodyPieces.joined(separator: "\n\n")
        let paragraphs = joined
            .split(omittingEmptySubsequences: true, whereSeparator: { $0.isNewline })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return ChapterContent(
            title: titleSeed ?? "",
            paragraphs: paragraphs,
            nextChapterURL: nextLink,
            previousChapterURL: prevLink
        )
    }

    // MARK: - Dispatch helpers

    private enum Step { case search, detail, catalog, chapter }

    private func engine(for step: Step) -> EnginePerStep.Engine {
        switch step {
        case .search: return rule.enginePerStep.search
        case .detail: return rule.enginePerStep.detail
        case .catalog: return rule.enginePerStep.catalog
        case .chapter: return rule.enginePerStep.chapter
        }
    }

    private func load(_ request: SourceRequest, step: Step) async throws -> WebPageSnapshot {
        switch engine(for: step) {
        case .http: return try await loader.fetchHTML(request)
        case .web:  return try await loader.renderHTML(request)
        }
    }

    private func baseRequest(for url: URL) -> SourceRequest {
        SourceRequest(
            url: url,
            method: .get,
            headers: rule.defaultHeaders,
            body: nil,
            encoding: rule.encoding,
            referer: rule.homepage
        )
    }

    /// Heuristic for catalog rows that resolved to site-nav links
    /// rather than real chapters. Universal across sources — fires
    /// only on shapes that can't be a chapter:
    /// - cross-host anchors,
    /// - self-links back to the catalog page itself,
    /// - empty / root paths,
    /// - well-known nav titles (`首页`, `登录`, etc.),
    /// - paths with no segment overlap with the catalog URL (after
    ///   stripping generic directory tokens like `book` / `read`).
    ///   A real chapter on `/books/12345.html` lives at
    ///   `/books/12345/N.html` or `/read/12345/N` — either way it
    ///   carries the `12345` segment; nav like `/sort/3` or `/` does
    ///   not. Chapter title text is too noisy to gate on, but title
    ///   blocklist + URL shape together drop the obvious cases.
    static func looksLikeNavLink(
        title: String,
        chapterURL: URL,
        catalogURL: URL
    ) -> Bool {
        // Different host → not a chapter of this book.
        if let chapHost = chapterURL.host, let catHost = catalogURL.host,
           chapHost.caseInsensitiveCompare(catHost) != .orderedSame {
            return true
        }
        let chapPath = chapterURL.path
        if chapPath.isEmpty || chapPath == "/" { return true }
        // Self-link back to the catalog page.
        if chapterURL.absoluteString == catalogURL.absoluteString { return true }
        if chapPath == catalogURL.path { return true }

        // Title blocklist: anchors whose visible text is one of the
        // well-known navigation labels found in nearly every Chinese
        // book-site header/footer. Conservative — only fires on exact
        // matches to short, unambiguous nav strings.
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if navTitleBlocklist.contains(trimmedTitle) { return true }

        // Path-segment overlap. A real chapter shares at least one
        // non-generic segment with the catalog URL (the book ID or
        // slug). Nav links target unrelated paths.
        let generic: Set<String> = [
            "book", "books", "novel", "novels", "read", "reading",
            "info", "list", "index", "home", "main", "html", "htm",
            "php", "asp", "jsp"
        ]
        func meaningfulSegments(_ path: String) -> Set<String> {
            var out: Set<String> = []
            for raw in path.split(separator: "/") {
                let seg = String(raw)
                let stem: String
                if let dot = seg.lastIndex(of: ".") {
                    stem = String(seg[..<dot])
                } else {
                    stem = seg
                }
                let lower = stem.lowercased()
                guard !lower.isEmpty, !generic.contains(lower) else { continue }
                out.insert(lower)
            }
            return out
        }
        let catSegments = meaningfulSegments(catalogURL.path)
        let chapSegments = meaningfulSegments(chapPath)
        if !catSegments.isEmpty, catSegments.isDisjoint(with: chapSegments) {
            return true
        }
        return false
    }

    /// Title-only blocklist of well-known navigation labels. Both
    /// simplified and traditional variants are included so the filter
    /// works across mainland and HK/TW mirrors of the same site.
    private static let navTitleBlocklist: Set<String> = [
        "首页", "首頁", "网站首页", "網站首頁", "主页", "主頁",
        "登录", "登錄", "注册", "註冊", "退出", "登出",
        "书架", "書架", "我的书架", "我的書架",
        "排行", "排行榜", "分类", "分類", "完本", "完結",
        "推荐", "推薦", "热门", "熱門", "最新", "全本",
        "男生", "女生", "男频", "男頻", "女频", "女頻",
        "帮助", "幫助", "客服", "反馈", "反饋",
        "关于", "關於", "关于我们", "關於我們",
        "联系", "聯繫", "联系我们", "聯繫我們",
        "公告", "投稿", "招聘", "友情链接", "友情鏈接",
        "简体", "簡體", "繁体", "繁體",
        "移动版", "移動版", "手机版", "手機版", "电脑版", "電腦版",
        "设置", "設置"
    ]
}

// MARK: -

private extension String {
    var nonEmptyTrimmed: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

private extension Optional where Wrapped == String {
    var nonEmptyTrimmed: String? {
        flatMap { $0.nonEmptyTrimmed }
    }
}
