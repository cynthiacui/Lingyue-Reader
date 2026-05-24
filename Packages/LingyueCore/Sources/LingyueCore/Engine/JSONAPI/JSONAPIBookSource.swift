import Foundation

/// Generic `BookSource` driven by `JSONAPIConfig`. The Swift side here
/// is fully site-agnostic — every URL, regex, JSON path, and boilerplate
/// fragment lives in the rule's `jsonAPI` block, which travels with
/// the imported JSON. Linking this type into `LingyueCore` does *not*
/// leak any per-site URLs into the binary, which is the property the
/// App Store target needs.
///
/// `search`, `detectBook`, and `fetchDetail` throw narrow errors: the
/// JSON-API engine handles catalog/chapter endpoints only. Detection
/// still happens through the rule's `detection` step on the in-app
/// browser path.
public struct JSONAPIBookSource: BookSource {
    public let rule: SourceRule
    public let config: JSONAPIConfig
    public let loader: any SourceHTMLLoading
    /// HTML fallback used for any step the `jsonAPI` block leaves out.
    /// Common case: a JSON catalog endpoint with no matching chapter
    /// endpoint — the rule's HTML chapter step still works, so we
    /// delegate to it instead of throwing. Search, detection, and detail
    /// also delegate here because the JSON API never covers them.
    public let fallback: RuleBasedBookSource

    public init(rule: SourceRule, config: JSONAPIConfig, loader: any SourceHTMLLoading) {
        self.rule = rule
        self.config = config
        self.loader = loader
        self.fallback = RuleBasedBookSource(rule: rule, loader: loader)
    }

    public var id: String { config.sourceID }
    public var displayName: String { rule.name }
    public var capabilities: SourceCapabilities { rule.capabilities }

    public func search(_ query: String) async throws -> [BookSearchResult] {
        if let search = config.search {
            return try await runJSONSearch(query: query, search: search)
        }
        return try await fallback.search(query)
    }

    private func runJSONSearch(
        query: String,
        search: JSONAPIConfig.Search
    ) async throws -> [BookSearchResult] {
        var lastError: Error?
        for template in search.endpointTemplates {
            let expanded: String
            do {
                expanded = try URLTemplate.expand(
                    template,
                    query: query,
                    encoding: search.queryEncoding ?? .utf8
                )
            } catch {
                lastError = error
                continue
            }
            guard let endpointURL = URL(string: expanded) else { continue }
            do {
                let snapshot = try await fetchJSONExpected(
                    url: endpointURL,
                    headers: search.headers ?? [:]
                )
                let results = try Self.decodeSearch(
                    json: snapshot.html,
                    search: search,
                    sourceID: id,
                    baseURL: endpointURL
                )
                if !results.isEmpty { return results }
            } catch {
                lastError = error
                continue
            }
        }
        if let lastError = lastError as? BookSourceError { throw lastError }
        return []
    }

    static func decodeSearch(
        json: String,
        search: JSONAPIConfig.Search,
        sourceID: String,
        baseURL: URL
    ) throws -> [BookSearchResult] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else {
            throw BookSourceError.parseFailed(field: "jsonAPI.search.json")
        }
        guard let itemsAny = JSONPath.resolve(search.itemsPath, in: root),
              let items = itemsAny as? [Any] else {
            return []
        }

        var results: [BookSearchResult] = []
        results.reserveCapacity(items.count)
        for item in items {
            guard let rawTitle = stringValue(JSONPath.resolve(search.titleField, in: item)) else {
                continue
            }
            let title = applyTitleTransforms(rawTitle, transforms: search.titleTransforms ?? [])
            guard !title.isEmpty else { continue }
            // Resolve the detail URL: explicit field path wins; otherwise
            // synthesize via `detailURLTemplate` + the value at `idField`.
            // Numeric IDs (`"id": 15089`) are stringified by `stringValue`.
            let detailURL: URL?
            if let fieldPath = search.detailURLField,
               let href = stringValue(JSONPath.resolve(fieldPath, in: item)) {
                detailURL = absoluteURL(from: href, baseURL: baseURL)
            } else if let template = search.detailURLTemplate {
                var tokens: [String: String] = [:]
                if let idField = search.idField,
                   let value = stringValue(JSONPath.resolve(idField, in: item)) {
                    tokens["id"] = value
                }
                detailURL = applyTemplate(template, tokens: tokens, index: nil)
            } else {
                detailURL = nil
            }
            guard let detailURL else { continue }
            let author = search.authorField
                .flatMap { stringValue(JSONPath.resolve($0, in: item)) }
                .map { applyTitleTransforms($0, transforms: []) }
                .flatMap { $0.isEmpty ? nil : $0 }
            let snippet = search.snippetField
                .flatMap { stringValue(JSONPath.resolve($0, in: item)) }
                .map { applyTitleTransforms($0, transforms: []) }
                .flatMap { $0.isEmpty ? nil : $0 }
            let coverURL = search.coverField
                .flatMap { stringValue(JSONPath.resolve($0, in: item)) }
                .flatMap { absoluteURL(from: $0, baseURL: baseURL) }
            results.append(
                BookSearchResult(
                    title: title,
                    author: author,
                    coverURL: coverURL,
                    snippet: snippet,
                    detailURL: detailURL,
                    sourceID: sourceID
                )
            )
        }
        return results
    }

    /// Coerces a `JSONPath.resolve` result into a String. Handles the
    /// common JSON types — `String`, `NSNumber`, `Int`, `Double`, `Bool` —
    /// because some APIs serve numeric book IDs (`"id": 15089`) rather
    /// than strings.
    private static func stringValue(_ raw: Any?) -> String? {
        switch raw {
        case let s as String: return s
        case let n as NSNumber:
            // NSNumber covers Bool, Int, Double bridged from JSON.
            // CFBoolean has the same NSNumber bridge — distinguish so
            // `true` doesn't become `"1"` silently.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        case let i as Int: return String(i)
        case let d as Double: return String(d)
        case let b as Bool: return b ? "true" : "false"
        default: return nil
        }
    }

    public func detectBook(in page: WebPageSnapshot) async throws -> BookDetection? {
        guard let base = try await fallback.detectBook(in: page) else { return nil }
        // SPA mirrors (e.g. bqg303.xyz) ship a shell whose visible `<h1>`
        // and `<title>` say the site name, not the book — the fallback's
        // site-name skip drops obvious banners, but later passes catch a
        // post-render `<h1>` that's still site-banner-shaped. Backfill via
        // the JSON detail API whenever the fallback's title is missing OR
        // banner-shaped; the API endpoint is the same one `fetchDetail`
        // will hit on import, so the cost is one extra request per page.
        guard let detail = config.detail else { return base }
        let trimmed = base.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let titleIsBanner = trimmed.isEmpty
            || RuleBasedBookSource.looksLikeSiteBanner(trimmed, siteName: rule.name)
        guard titleIsBanner else { return base }
        guard let tokens = try? Self.extractTokens(
            from: page.finalURL,
            using: config.idExtractors
        ), tokens["bookID"] != nil else {
            return base
        }
        for template in detail.endpointTemplates {
            guard let endpointURL = Self.applyTemplate(template, tokens: tokens, index: nil) else {
                continue
            }
            guard let snapshot = try? await fetchJSONExpected(
                url: endpointURL,
                headers: detail.headers ?? [:]
            ) else { continue }
            guard let resolved = try? Self.decodeDetail(
                json: snapshot.html,
                detail: detail,
                sourceID: id,
                requestedURL: page.finalURL
            ), !resolved.title.isEmpty else { continue }
            return BookDetection(
                confidence: base.confidence,
                detailURL: base.detailURL,
                title: resolved.title,
                sourceID: base.sourceID
            )
        }
        return base
    }

    public func fetchDetail(url: URL) async throws -> BookDetail {
        guard let detail = config.detail else {
            return try await fallback.fetchDetail(url: url)
        }
        guard Self.urlMatchesAnyHostPattern(url, patterns: rule.detection.hostPatterns) else {
            throw BookSourceError.unsupportedURL(url)
        }
        let tokens = try Self.extractTokens(from: url, using: config.idExtractors)

        var lastError: Error?
        for template in detail.endpointTemplates {
            guard let endpointURL = Self.applyTemplate(template, tokens: tokens, index: nil) else {
                continue
            }
            do {
                let snapshot = try await fetchJSONExpected(
                    url: endpointURL,
                    headers: detail.headers ?? [:]
                )
                if let resolved = try Self.decodeDetail(
                    json: snapshot.html,
                    detail: detail,
                    sourceID: id,
                    requestedURL: url
                ) {
                    return resolved
                }
            } catch {
                lastError = error
                continue
            }
        }
        // Same fallback as catalog/chapter: sibling mirrors share the URL
        // shape but the API doesn't recognize their IDs. Drop to the HTML
        // detail path; it throws on SPA shells, so we ignore the error.
        if let html = try? await fallback.fetchDetail(url: url) {
            return html
        }
        if let lastError = lastError as? BookSourceError { throw lastError }
        if let lastError { throw BookSourceError.loadFailed(reason: String(describing: lastError)) }
        throw BookSourceError.parseFailed(field: "jsonAPI.empty-detail")
    }

    static func decodeDetail(
        json: String,
        detail: JSONAPIConfig.Detail,
        sourceID: String,
        requestedURL: URL
    ) throws -> BookDetail? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else {
            throw BookSourceError.parseFailed(field: "jsonAPI.detail.json")
        }
        let scope: Any
        if let path = detail.itemsPath, !path.isEmpty {
            guard let resolved = JSONPath.resolve(path, in: root) else { return nil }
            scope = resolved
        } else {
            scope = root
        }
        guard let rawTitle = stringValue(JSONPath.resolve(detail.titleField, in: scope)),
              !rawTitle.isEmpty
        else { return nil }
        let title = applyTitleTransforms(rawTitle, transforms: detail.titleTransforms ?? [])

        let author: String? = detail.authorField.flatMap {
            stringValue(JSONPath.resolve($0, in: scope))
        }
        let intro: String? = detail.introField.flatMap {
            stringValue(JSONPath.resolve($0, in: scope))
        }
        let category: String? = detail.categoryField.flatMap {
            stringValue(JSONPath.resolve($0, in: scope))
        }
        let cover: URL? = detail.coverField
            .flatMap { stringValue(JSONPath.resolve($0, in: scope)) }
            .flatMap { URL(string: $0) }
        let status: String? = detail.statusField.flatMap {
            stringValue(JSONPath.resolve($0, in: scope))
        }
        let lastChapter: String? = detail.lastChapterField.flatMap {
            stringValue(JSONPath.resolve($0, in: scope))
        }

        return BookDetail(
            title: title,
            author: author,
            coverURL: cover,
            description: intro,
            tags: category.map { [$0] } ?? [],
            status: status,
            statistics: lastChapter,
            catalogURL: requestedURL,
            detailURL: requestedURL,
            sourceID: sourceID
        )
    }

    // MARK: - Catalog

    public func fetchCatalog(url: URL) async throws -> [ChapterLink] {
        guard let catalog = config.catalog else {
            return try await fallback.fetchCatalog(url: url)
        }
        guard Self.urlMatchesAnyHostPattern(url, patterns: rule.detection.hostPatterns) else {
            throw BookSourceError.unsupportedURL(url)
        }
        let tokens = try Self.extractTokens(from: url, using: config.idExtractors)

        var lastError: Error?
        for template in catalog.endpointTemplates {
            guard let endpointURL = Self.applyTemplate(template, tokens: tokens, index: nil) else {
                continue
            }
            do {
                let snapshot = try await fetchJSONExpected(
                    url: endpointURL,
                    headers: catalog.headers ?? [:]
                )
                let links = try Self.decodeCatalog(
                    json: snapshot.html,
                    catalog: catalog,
                    tokens: tokens,
                    baseURL: url
                )
                if !links.isEmpty { return links }
            } catch let error as BookSourceError {
                lastError = error
                continue
            } catch {
                lastError = error
                continue
            }
        }
        // The same JSON API may serve a constellation of mirror sites;
        // sister mirrors can share the URL shape but have book IDs the
        // API doesn't recognize, so every endpoint returns
        // `{"list":null}`. Falling back to the HTML catalog block —
        // when the rule defines one — lets one rule cover both
        // API-backed and HTML-backed mirrors.
        if !rule.catalog.chaptersSelector.isEmpty {
            if let html = try? await fallback.fetchCatalog(url: url), !html.isEmpty {
                return html
            }
        }
        if let lastError = lastError as? BookSourceError { throw lastError }
        if let lastError { throw BookSourceError.loadFailed(reason: String(describing: lastError)) }
        throw BookSourceError.parseFailed(field: "jsonAPI.empty-catalog")
    }

    static func decodeCatalog(
        json: String,
        catalog: JSONAPIConfig.Catalog,
        tokens: [String: String],
        baseURL: URL
    ) throws -> [ChapterLink] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else {
            throw BookSourceError.parseFailed(field: "jsonAPI.catalog.json")
        }
        guard let itemsAny = JSONPath.resolve(catalog.itemsPath, in: root),
              let items = itemsAny as? [Any] else {
            return []
        }

        var links: [ChapterLink] = []
        links.reserveCapacity(items.count)
        for (offset, item) in items.enumerated() {
            let rawTitle: String?
            if let titleField = catalog.titleField {
                rawTitle = JSONPath.resolve(titleField, in: item) as? String
            } else {
                rawTitle = item as? String
            }
            guard let raw = rawTitle else { continue }
            let title = applyTitleTransforms(raw, transforms: catalog.titleTransforms ?? [])
            guard !title.isEmpty else { continue }

            let chapterURL: URL?
            if let urlField = catalog.urlField,
               let href = JSONPath.resolve(urlField, in: item) as? String {
                chapterURL = absoluteURL(from: href, baseURL: baseURL)
            } else if let template = catalog.urlTemplate {
                guard let synthesized = applyTemplate(template, tokens: tokens, index: offset + 1) else {
                    continue
                }
                chapterURL = absoluteURL(from: synthesized.absoluteString, baseURL: baseURL)
            } else {
                chapterURL = nil
            }
            guard let chapterURL else { continue }
            links.append(ChapterLink(title: title, url: chapterURL, index: offset))
        }
        return links
    }

    // MARK: - Chapter

    public func fetchChapter(url: URL) async throws -> ChapterContent {
        guard let chapter = config.chapter else {
            return try await fallback.fetchChapter(url: url)
        }
        guard Self.urlMatchesAnyHostPattern(url, patterns: rule.detection.hostPatterns) else {
            throw BookSourceError.unsupportedURL(url)
        }
        let tokens = try Self.extractTokens(from: url, using: config.idExtractors)

        var lastError: Error?
        for template in chapter.endpointTemplates {
            guard let endpointURL = Self.applyTemplate(template, tokens: tokens, index: nil) else {
                continue
            }
            do {
                let snapshot = try await fetchJSONExpected(
                    url: endpointURL,
                    headers: chapter.headers ?? [:]
                )
                let content = try Self.decodeChapter(json: snapshot.html, chapter: chapter)
                if !content.paragraphs.isEmpty { return content }
            } catch let error as BookSourceError {
                lastError = error
                continue
            } catch {
                lastError = error
                continue
            }
        }
        // Same rationale as `fetchCatalog`: mirror sites that share the
        // rule's URL shape but not the API's book IDs fail every
        // endpoint with empty content. The HTML chapter block in the
        // rule is a working second path for those mirrors.
        if !(rule.chapter.bodyField.selector?.isEmpty ?? true) {
            if let html = try? await fallback.fetchChapter(url: url), !html.paragraphs.isEmpty {
                return html
            }
        }
        if let lastError = lastError as? BookSourceError { throw lastError }
        if let lastError { throw BookSourceError.loadFailed(reason: String(describing: lastError)) }
        throw BookSourceError.parseFailed(field: "jsonAPI.empty-chapter")
    }

    static func decodeChapter(
        json: String,
        chapter: JSONAPIConfig.Chapter
    ) throws -> ChapterContent {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else {
            throw BookSourceError.parseFailed(field: "jsonAPI.chapter.json")
        }
        let title: String
        if let titleField = chapter.titleField,
           let raw = JSONPath.resolve(titleField, in: root) as? String {
            title = applyTitleTransforms(raw, transforms: [.decodeEntities, .stripHTML, .collapseWhitespace, .trim])
        } else {
            title = ""
        }
        guard let bodyRaw = JSONPath.resolve(chapter.bodyField, in: root) as? String else {
            return ChapterContent(title: title, paragraphs: [])
        }
        let paragraphs = applyBodyTransforms(
            bodyRaw,
            transforms: chapter.bodyTransforms ?? [],
            boilerplate: chapter.boilerplateFragments ?? []
        )
        let cleaned = ChapterBodySanitizer.sanitize(paragraphs: paragraphs, title: title)
        return ChapterContent(title: title, paragraphs: cleaned)
    }

    // MARK: - URL + templates

    /// Matches a URL host against the rule's detection host patterns.
    /// Patterns may be exact (`example.com`), suffix-glob (`*.example.com`),
    /// or substring-glob (`*bqg*`).
    static func urlMatchesAnyHostPattern(_ url: URL, patterns: [String]) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return patterns.contains(where: { hostMatches(host: host, pattern: $0.lowercased()) })
    }

    private static func hostMatches(host: String, pattern: String) -> Bool {
        if !pattern.contains("*") {
            return host == pattern || host.hasSuffix("." + pattern)
        }
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        var searchStart = host.startIndex
        // Leading "*" lets the first part match anywhere; otherwise it must be a prefix.
        for (i, fragment) in parts.enumerated() where !fragment.isEmpty {
            let isPrefix = (i == 0 && !pattern.hasPrefix("*"))
            let isSuffix = (i == parts.count - 1 && !pattern.hasSuffix("*"))
            guard let range = host.range(of: fragment, range: searchStart..<host.endIndex) else {
                return false
            }
            if isPrefix && range.lowerBound != host.startIndex { return false }
            if isSuffix && range.upperBound != host.endIndex { return false }
            searchStart = range.upperBound
        }
        return true
    }

    /// Extracts every configured token from the URL by trying each
    /// pattern in turn. Tokens missing from the URL simply don't end up
    /// in the result map — templates that reference them will fail at
    /// substitution time, which is the right place to surface the error.
    static func extractTokens(
        from url: URL,
        using extractors: [String: [String]]
    ) throws -> [String: String] {
        let path = routePath(from: url)
        var tokens: [String: String] = [:]
        for (name, patterns) in extractors {
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(path.startIndex..<path.endIndex, in: path)
                if let match = regex.firstMatch(in: path, range: range),
                   match.numberOfRanges > 1,
                   let captureRange = Range(match.range(at: 1), in: path) {
                    tokens[name] = String(path[captureRange])
                    break
                }
            }
        }
        // Synthetic host/origin tokens. Lets a template say
        // `https://{originHost}/api/book?id={bookID}` so the engine hits
        // the same-host API on whatever mirror the user landed on; named
        // backend mirrors can sit later in the list as fallbacks. Some
        // ecosystems have many mirrors with independent ID spaces, so
        // cross-host fallback is unreliable — this lets the rule prefer
        // the local backend.
        if let host = url.host, !host.isEmpty {
            tokens["originHost"] = host
            let scheme = url.scheme ?? "https"
            tokens["originScheme"] = scheme
            tokens["origin"] = "\(scheme)://\(host)"
        }
        return tokens
    }

    /// SPA-style mirrors (e.g., `bqg355.xyz/#/book/<id>/`) keep the
    /// route in the URL fragment; everyone else uses `url.path`. The
    /// fragment-fallback only fires when `path` is empty or "/" so a
    /// normal URL like `/book/<id>` keeps its query/fragment untouched.
    private static func routePath(from url: URL) -> String {
        let rawPath = url.path.lowercased()
        let rawFragment = url.fragment(percentEncoded: false)?.lowercased() ?? ""
        guard (rawPath.isEmpty || rawPath == "/"), !rawFragment.isEmpty else {
            return rawPath
        }
        return rawFragment.hasPrefix("/") ? rawFragment : "/" + rawFragment
    }

    /// Replaces `{tokenName}` and (optionally) `{index}` in a URL
    /// template. Returns nil if any referenced token is missing or the
    /// substituted string fails to parse as a URL.
    static func applyTemplate(
        _ template: String,
        tokens: [String: String],
        index: Int?
    ) -> URL? {
        var output = template
        var missing = false
        let regex = try? NSRegularExpression(pattern: #"\{([A-Za-z0-9_]+)\}"#)
        let range = NSRange(template.startIndex..<template.endIndex, in: template)
        let matches = regex?.matches(in: template, range: range) ?? []
        for match in matches.reversed() {
            guard let nameRange = Range(match.range(at: 1), in: template),
                  let fullRange = Range(match.range, in: template) else { continue }
            let name = String(template[nameRange])
            let replacement: String?
            if name == "index", let index { replacement = String(index) }
            else { replacement = tokens[name] }
            if let replacement {
                output.replaceSubrange(
                    output.range(of: String(template[fullRange])) ?? output.startIndex..<output.startIndex,
                    with: replacement
                )
            } else {
                missing = true
                break
            }
        }
        if missing { return nil }
        return URL(string: output)
    }

    // MARK: - Title + body transforms

    static func applyTitleTransforms(
        _ raw: String,
        transforms: [JSONAPIConfig.TitleTransform]
    ) -> String {
        var text = raw
        let defaultPipeline: [JSONAPIConfig.TitleTransform] = transforms.isEmpty
            ? [.decodeEntities, .stripHTML, .collapseWhitespace, .trim]
            : transforms
        for transform in defaultPipeline {
            switch transform {
            case .decodeEntities: text = decodeNamedEntities(text)
            case .stripHTML: text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            case .collapseWhitespace: text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            case .trim: text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }

    static func applyBodyTransforms(
        _ raw: String,
        transforms: [JSONAPIConfig.BodyTransform],
        boilerplate: [String]
    ) -> [String] {
        var text = raw
        var paragraphs: [String]?
        for transform in transforms {
            switch transform {
            case .normalizeLineEndings:
                text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            case .brToNewline:
                text = text.replacingOccurrences(
                    of: #"<\s*br\s*/?\s*>"#,
                    with: "\n",
                    options: [.regularExpression, .caseInsensitive]
                )
            case .stripHTML:
                text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            case .decodeEntities:
                text = decodeNamedEntities(text)
            case .splitLines:
                paragraphs = text
                    .components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            case .filterBoilerplate:
                let lines = paragraphs ?? text.components(separatedBy: "\n")
                paragraphs = lines.filter { line in !isBoilerplate(line, fragments: boilerplate) }
            case .trim:
                if let p = paragraphs {
                    paragraphs = p.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                } else {
                    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        if let p = paragraphs { return p }
        // No explicit splitLines — fall back to one paragraph per non-empty line.
        return text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func isBoilerplate(_ line: String, fragments: [String]) -> Bool {
        guard line.count <= 80 else { return false }
        return fragments.contains { fragment in
            line.localizedCaseInsensitiveContains(fragment)
        }
    }

    private static func decodeNamedEntities(_ text: String) -> String {
        var decoded = text
        let map: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&#39;", "'"),
            ("&nbsp;", " "),
            ("&ldquo;", "\u{201C}"),
            ("&rdquo;", "\u{201D}"),
            ("&lsquo;", "\u{2018}"),
            ("&rsquo;", "\u{2019}"),
            ("&hellip;", "\u{2026}"),
            ("&mdash;", "\u{2014}"),
            ("&ndash;", "\u{2013}")
        ]
        for (entity, value) in map {
            decoded = decoded.replacingOccurrences(of: entity, with: value)
        }
        return decoded
    }

    private static func absoluteURL(from href: String, baseURL: URL) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("#"),
              !trimmed.lowercased().hasPrefix("javascript:") else {
            return nil
        }
        guard var components = URLComponents(
            url: URL(string: trimmed, relativeTo: baseURL)?.absoluteURL ?? baseURL,
            resolvingAgainstBaseURL: true
        ) else {
            return nil
        }
        components.fragment = nil
        if components.scheme == "http",
           baseURL.scheme == "https",
           components.host == baseURL.host {
            components.scheme = "https"
        }
        return components.url
    }

    // MARK: - Fetch with HTML-response retry

    /// Fetches a URL the engine expects to return JSON. If the response is
    /// actually HTML (a sign that the upstream CDN is holding an HTML page
    /// in its cache for what should be a JSON endpoint — observed on at
    /// least one site whose nginx cache key didn't distinguish HTML
    /// routes from `/ajaxService?…` JSON routes), retries the same
    /// request once with a cache-buster query param so the CDN either
    /// cache-misses or stores the busted URL separately.
    private func fetchJSONExpected(
        url: URL,
        headers: [String: String]
    ) async throws -> WebPageSnapshot {
        let snapshot = try await loader.fetchHTML(
            SourceRequest(url: url, headers: headers)
        )
        guard Self.responseLooksLikeHTML(snapshot) else { return snapshot }
        let bustedURL = Self.withCacheBuster(url)
        return try await loader.fetchHTML(
            SourceRequest(url: bustedURL, headers: headers)
        )
    }

    /// True when the response Content-Type announces HTML, or when the
    /// body unambiguously opens with `<!doctype html>` / `<html>`. The
    /// body sniff covers renderer-sourced snapshots that don't carry
    /// response headers — though those don't hit JSON-API endpoints in
    /// practice, the check stays cheap and safe.
    private static func responseLooksLikeHTML(_ snapshot: WebPageSnapshot) -> Bool {
        if let contentType = snapshot.responseHeaders["content-type"],
           contentType.lowercased().contains("text/html") {
            return true
        }
        let head = snapshot.html
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(15)
            .lowercased()
        return head.hasPrefix("<!doctype html") || head.hasPrefix("<html")
    }

    /// Appends `_=<unix-ms>` to the URL's query so the CDN treats the
    /// retry as a distinct cache key from the (possibly stale) primary.
    /// Falls back to the original URL on the (vanishingly rare) case
    /// where `URLComponents` can't recompose.
    private static func withCacheBuster(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(
            name: "_",
            value: String(Int(Date().timeIntervalSince1970 * 1000))
        ))
        components.queryItems = items
        return components.url ?? url
    }
}

/// Tiny dotted-path walker for `JSONSerialization` output. `"a.b.c"`
/// drills through `[String: Any]` levels. Numeric segments index into
/// arrays. `""` returns the root. Returns nil rather than throwing
/// when a segment doesn't resolve, so callers can decide whether a
/// miss is fatal or merely "no value here."
enum JSONPath {
    static func resolve(_ path: String, in root: Any) -> Any? {
        if path.isEmpty { return root }
        var cursor: Any? = root
        for segment in path.split(separator: ".") {
            guard let current = cursor else { return nil }
            if let index = Int(segment), let array = current as? [Any] {
                cursor = (0..<array.count).contains(index) ? array[index] : nil
            } else if let dict = current as? [String: Any] {
                cursor = dict[String(segment)]
            } else {
                return nil
            }
        }
        return cursor
    }
}
