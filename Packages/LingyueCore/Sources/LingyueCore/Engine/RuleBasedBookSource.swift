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
            guard
                let title = try SelectorEngine.resolveSingle(
                    step.titleField, scope: row, baseURL: snapshot.finalURL
                ),
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
        let rawTitle = try SelectorEngine.resolveSingle(
            rule.detail.titleField,
            scope: document,
            baseURL: page.finalURL
        )
        // Discard a resolved title that echoes the rule's own display
        // name — that's the site logo, not the book title (common when
        // `detail.titleField` is the analyzer's default `h1` and the
        // page header carries the site name in an `<h1>` of its own).
        // The browser's fallback chain (page `<title>` → source name)
        // produces a better user-facing label.
        let trimmed = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String?
        if let trimmed, !trimmed.isEmpty,
           trimmed.caseInsensitiveCompare(rule.name) != .orderedSame {
            title = trimmed
        } else {
            title = nil
        }
        return BookDetection(
            confidence: min(confidence, 1.0),
            detailURL: canonical,
            title: title,
            sourceID: id
        )
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

        guard let title = try SelectorEngine.resolveSingle(
            step.titleField, scope: document, baseURL: snapshot.finalURL
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
