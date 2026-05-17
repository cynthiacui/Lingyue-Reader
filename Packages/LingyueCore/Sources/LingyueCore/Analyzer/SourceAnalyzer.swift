import Foundation
import SwiftSoup

public extension SourceRule {
    /// Empty draft for new user-authored rules. Homepage defaults to
    /// `https://example.com` per the Phase 6.2 placeholder invariant
    /// (URL placeholders must never reference a pirate-adjacent host).
    /// Capabilities default to false so a half-edited rule can't leak
    /// into Discovery search before §3.5.2 derivation marks it ready.
    static func makeBlankDraft() -> SourceRule {
        SourceRule(
            name: "",
            homepage: URL(string: "https://example.com")!,
            capabilities: SourceCapabilities(
                supportsSearch: false,
                showInSearchBar: false,
                supportsBrowserImport: false,
                requiresWebRender: false
            ),
            enginePerStep: .default,
            encoding: .auto,
            defaultHeaders: [:],
            detection: DetectionStep(hostPatterns: []),
            search: nil,
            detail: DetailStep(
                titleField: FieldSelector(),
                catalogURLField: FieldSelector()
            ),
            catalog: CatalogStep(
                chaptersSelector: "",
                titleField: FieldSelector(),
                urlField: FieldSelector()
            ),
            chapter: ChapterStep(
                titleField: FieldSelector(),
                bodyField: FieldSelector()
            )
        )
    }
}

/// Phase 3.2.1 — URL Analyzer pipeline (v1, P1–P3).
///
/// **What this slice ships:**
/// - **P1** Homepage fetch via `SourceHTMLLoading` (plain HTTP, no
///   WebKit fallback). JS-only pages get a low-confidence note rather
///   than a fake green.
/// - **P2** Host classification (with `www.`-stripping wildcard
///   heuristic) + name extraction from `<title>` / `<meta>`.
/// - **P3** Search-form discovery. First `<form>` whose name/id/action
///   contains a search-flavoured token wins; URL template + body
///   template are synthesized from the form's `action` + inputs.
///   Optional smoke-test executes the proposed search and verifies a
///   non-empty parseable result set when the user provided a keyword.
///
/// **What this slice does NOT ship:**
/// - P4 (catalog detection from example book URL) and P5 (chapter-body
///   detection) — both deferred per PHASES.md §3.2.1 until an
///   example-book-URL passing rate is measurable. Detail / catalog /
///   chapter blocks still report `.notRun` with a note steering the
///   user toward manual Test on the Review screen.
///
/// **Capability invariant.** The analyzer never writes
/// `SourceCapabilities` directly. It emits a draft `SourceRule` with
/// every flag false, plus an `AnalysisReport` keyed by block;
/// `SourceReviewView.derivedCapabilities` is the only place that flips
/// `supportsSearch` / `supportsBrowserImport` on. The split lets users
/// hand-edit selectors in §3.4 without leaving stale capabilities
/// behind (see PHASES.md §3.5.2).
public struct AnalyzerInput: Equatable, Sendable {
    public let homepage: URL
    public let exampleBookURL: URL?
    /// Optional sample chapter-body URL. Today the chapter analyzer (P5)
    /// derives one from the catalog crawl, but accepting an explicit URL
    /// lets the simple authoring flow pre-fill the chapter Test sheet
    /// even when catalog discovery hasn't run.
    public let chapterURL: URL?
    /// Optional sample search-results URL — a fully-rendered URL the user
    /// pasted from their browser (with their keyword already in the query
    /// string). When present together with `testKeyword`, the analyzer
    /// derives the search step deterministically from this URL instead of
    /// scanning the homepage for a `<form>`. Almost every Chinese-language
    /// book site we've fingerprinted uses GET search, so a pasted URL is
    /// vastly more reliable than form discovery.
    public let searchResultURL: URL?
    public let testKeyword: String?
    /// Optional user-chosen display name. When non-empty, overrides the
    /// `<title>`-derived suggestion so the source list shows the name the
    /// user typed.
    public let customName: String?

    public init(
        homepage: URL,
        exampleBookURL: URL? = nil,
        chapterURL: URL? = nil,
        searchResultURL: URL? = nil,
        testKeyword: String? = nil,
        customName: String? = nil
    ) {
        self.homepage = homepage
        self.exampleBookURL = exampleBookURL
        self.chapterURL = chapterURL
        self.searchResultURL = searchResultURL
        self.testKeyword = testKeyword
        self.customName = customName
    }
}

public struct AnalysisReport: Equatable, Codable, Sendable {
    public enum BlockConfidence: String, Equatable, Codable, Sendable {
        case green    // ≥ 0.8 — analyzer matched cleanly
        case yellow   // 0.5–0.8 — ambiguous match
        case red      // < 0.5 — no match / JS-only / unsupported
        case notRun   // analyzer didn't reach this block (P4/P5 today)
    }

    public var search: BlockConfidence
    public var detail: BlockConfidence
    public var catalog: BlockConfidence
    public var chapter: BlockConfidence

    /// Optional reason text per block — surfaced as secondary copy on
    /// the Review screen. Keys: "search" / "detail" / "catalog" /
    /// "chapter" / "detection". Values are short human-readable strings.
    public var notes: [String: String]

    /// Inferred host patterns from the homepage URL. Rendered read-only
    /// on the Review screen above the per-block status list
    /// (`检测到域名：xxx`); never editable from the default flow.
    public var detectedHosts: [String]

    /// Suggested display name. P2 pulls `<title>` (stripped of common
    /// site-name separators); falls back to the bare host.
    public var suggestedName: String?

    /// True iff P1 short-circuited (network failure, empty body, or
    /// HTML that fails to parse). The Review screen uses this to show
    /// the "仅识别了域名" banner so the user knows the analyzer didn't
    /// actually inspect the page.
    public var isStub: Bool

    /// First chapter URL P4 followed off the example book page. Used
    /// by the Review screen to prefill the chapter-block Test sheet so
    /// the user doesn't have to re-find the URL they pasted upstream.
    /// nil when P4 didn't run or found no rows.
    public var firstChapterURL: URL?

    public init(
        search: BlockConfidence = .notRun,
        detail: BlockConfidence = .notRun,
        catalog: BlockConfidence = .notRun,
        chapter: BlockConfidence = .notRun,
        notes: [String: String] = [:],
        detectedHosts: [String] = [],
        suggestedName: String? = nil,
        isStub: Bool = false,
        firstChapterURL: URL? = nil
    ) {
        self.search = search
        self.detail = detail
        self.catalog = catalog
        self.chapter = chapter
        self.notes = notes
        self.detectedHosts = detectedHosts
        self.suggestedName = suggestedName
        self.isStub = isStub
        self.firstChapterURL = firstChapterURL
    }
}

public enum SourceAnalyzer {
    /// Run the v1 (P1–P3) analyzer against `input`. `loader` defaults to
    /// a stock `HTTPSourceLoader`; tests inject a stub conforming to
    /// `SourceHTMLLoading` to avoid network.
    ///
    /// The pipeline is deliberately fail-soft: any P1 network failure
    /// degrades the report to URL-parsing-only (matches the prior stub
    /// behaviour) rather than throwing. P2/P3 only run when P1
    /// produced a parseable document.
    public static func analyze(
        _ input: AnalyzerInput,
        loader: any SourceHTMLLoading = HTTPSourceLoader()
    ) async -> (rule: SourceRule, report: AnalysisReport) {
        // P0 — seed rule + report from URL parsing alone. This is what
        // the report degrades to if P1 fails.
        let parsedHost = input.homepage.host(percentEncoded: false) ?? ""
        let strippedHost = parsedHost.hasPrefix("www.") ? String(parsedHost.dropFirst(4)) : parsedHost
        var rule = SourceRule.makeBlankDraft()
        rule.name = strippedHost
        rule.homepage = input.homepage
        rule.detection.hostPatterns = parsedHost.isEmpty ? [] : [parsedHost]

        var report = AnalysisReport(
            detectedHosts: parsedHost.isEmpty ? [] : [parsedHost],
            suggestedName: strippedHost.isEmpty ? nil : strippedHost,
            isStub: true
        )

        if parsedHost.isEmpty {
            report.notes["detection"] = "无法从 URL 解析出域名。"
            return (rule, report)
        }

        // P1 — fetch homepage. Soft-fail returns the URL-only report.
        let request = SourceRequest(url: input.homepage, method: .get, encoding: .auto)
        let snapshot: WebPageSnapshot
        do {
            snapshot = try await loader.fetchHTML(request)
        } catch {
            report.notes["detection"] = "主页抓取失败,仅按 URL 推断域名。重试或在「高级修复」中手动配置。"
            return (rule, report)
        }

        let document: Document
        do {
            document = try SwiftSoup.parse(snapshot.html, snapshot.finalURL.absoluteString)
        } catch {
            report.notes["detection"] = "主页内容无法解析为 HTML,可能是 JS 渲染页面。请使用「测试」或在「高级修复」中切换到 WKWebView 引擎。"
            return (rule, report)
        }

        // JS-only heuristic: an HTML doc with effectively no body text
        // is almost certainly client-rendered. Don't pretend to have
        // analyzed the search form.
        let bodyText = (try? document.body()?.text()) ?? ""
        let isLikelyJSOnly = bodyText.trimmingCharacters(in: .whitespacesAndNewlines).count < 200
        if isLikelyJSOnly {
            report.notes["detection"] = "主页文本极少,可能是 JS 渲染页面。手动「测试」或在「高级修复」中切换到 WKWebView。"
            // Fall through — P2 host classification still runs (final
            // URL is canonical even on JS-only sites). P3 will skip on
            // the same heuristic.
        }

        // P2 — final-URL host classification + display name.
        let finalHost = snapshot.finalURL.host(percentEncoded: false) ?? parsedHost
        let strippedFinal = finalHost.hasPrefix("www.") ? String(finalHost.dropFirst(4)) : finalHost
        rule.detection.hostPatterns = uniqueHosts(parsedHost: parsedHost, finalHost: finalHost)
        report.detectedHosts = rule.detection.hostPatterns

        let displayName = extractDisplayName(from: document) ?? strippedFinal
        rule.name = displayName
        report.suggestedName = displayName

        // We have a parseable doc — exit the stub mode flag so the
        // Review banner doesn't pretend nothing ran.
        report.isStub = false

        // P3 — search-step derivation. Prefer an explicit search-result
        // URL (deterministic, GET, keyword → {query}) when the user
        // provided one; otherwise fall back to homepage form scraping.
        // The URL path is dramatically more reliable on the long tail of
        // Chinese book sites where the `<form>` markup is hand-rolled
        // and rarely contains the search-flavoured tokens we look for.
        let urlDerived: DerivedSearch? = {
            guard
                let searchURL = input.searchResultURL,
                let keyword = input.testKeyword,
                !keyword.isEmpty
            else { return nil }
            return deriveSearchFromURL(searchURL: searchURL, keyword: keyword)
        }()

        // Unified search-refinement helper: execute the candidate step
        // with the user's keyword, refine selectors from the live HTML,
        // and fall back to a smoke-test when refinement fails. Used by
        // both the URL-derived and form-discovered branches so POST
        // sites (xbanxia, xsw, nunu) also get real selectors instead of
        // the `.result, .result-item, ...` placeholder.
        func refineAndRecord(step initialStep: SearchStep, baseConfidence: AnalysisReport.BlockConfidence, baseNote: String?) async {
            var step = initialStep
            // Always probe — if the user didn't supply a keyword we use a
            // single common Chinese character that appears in nearly every
            // novel title. The probe is only for HTML structure discovery;
            // the runtime substitutes the real query at request time.
            let userKeyword = input.testKeyword?.trimmingCharacters(in: .whitespacesAndNewlines)
            let keyword = (userKeyword?.isEmpty == false) ? userKeyword! : "一"
            let refined = await analyzeSearchResults(
                step: step,
                keyword: keyword,
                homepage: input.homepage,
                encoding: rule.encoding,
                loader: loader
            )
            if let refined {
                step.resultsSelector = refined.resultsSelector
                step.titleField = refined.titleField
                step.detailURLField = refined.detailURLField
                rule.search = step
                report.search = refined.confidence
                if let note = refined.note { report.notes["search"] = note }
                return
            }
            // Refinement failed — fall through to smoke-test so the user
            // still gets a confidence signal.
            rule.search = step
            report.search = baseConfidence
            if let note = baseNote { report.notes["search"] = note }
            let verdict = await verifySearch(
                step: step,
                keyword: keyword,
                encoding: rule.encoding,
                loader: loader
            )
            if let verdict {
                report.search = verdict.confidence
                if let note = verdict.note { report.notes["search"] = note }
            }
        }

        if let urlDerived {
            await refineAndRecord(
                step: urlDerived.step,
                baseConfidence: urlDerived.confidence,
                baseNote: urlDerived.note
            )
        } else if !isLikelyJSOnly {
            let p3 = discoverSearchForm(in: document, baseURL: snapshot.finalURL)
            if let p3 {
                // `refineAndRecord` already fetches with the user's
                // keyword, refines selectors from the live response,
                // and smoke-tests when refinement fails — so the older
                // standalone `verifySearch` follow-up is redundant.
                await refineAndRecord(
                    step: p3.step,
                    baseConfidence: p3.confidence,
                    baseNote: p3.note
                )
            } else {
                report.search = .red
                report.notes["search"] = "未找到搜索表单 — 该站点可能使用 AJAX/JS 搜索,请运行「测试」或在「高级修复」中手动配置。"
            }
        }

        // P4 — catalog detection. Requires an example book URL; the
        // analyzer is too lossy without one (crawling homepage → a
        // single book is fragile across site layouts).
        if let exampleBook = input.exampleBookURL {
            let p4 = await analyzeCatalog(
                exampleBookURL: exampleBook,
                encoding: rule.encoding,
                loader: loader
            )
            if let p4 {
                rule.catalog.chaptersSelector = p4.chaptersSelector
                rule.catalog.titleField = p4.titleField
                rule.catalog.urlField = p4.urlField
                // Default detail step pointing the catalog-URL field at
                // the book page itself. The catalog selector lives on
                // the same DOM, so a no-op self-link is correct.
                rule.detail.titleField = FieldSelector(
                    selector: "h1",
                    attribute: nil,
                    transforms: []
                )
                // Catalog lives on the detail page itself. `useBaseURL`
                // discards whatever the (nil-selector) extractor pulls
                // and emits the request URL — i.e. the detail URL — so
                // the engine's catalog fetch is a no-op re-read of the
                // same page rather than chasing whole-document text.
                rule.detail.catalogURLField = FieldSelector(
                    selector: nil,
                    attribute: nil,
                    transforms: [.useBaseURL]
                )
                report.detail = .yellow
                report.catalog = p4.confidence
                report.notes["detail"] = "已猜测 `<h1>` 为书名;目录与详情同页时无需另设目录链接。请运行「测试」验证。"
                if let note = p4.note { report.notes["catalog"] = note }

                // P5 — chapter body detection. Use the first proposed
                // chapter URL as the probe.
                report.firstChapterURL = p4.firstChapterURL
                if let firstURL = p4.firstChapterURL {
                    let p5 = await analyzeChapterBody(
                        chapterURL: firstURL,
                        encoding: rule.encoding,
                        loader: loader
                    )
                    if let p5 {
                        rule.chapter.titleField = FieldSelector(
                            selector: "h1",
                            attribute: nil,
                            transforms: []
                        )
                        rule.chapter.bodyField = p5.bodyField
                        report.chapter = p5.confidence
                        if let note = p5.note { report.notes["chapter"] = note }
                    } else {
                        report.chapter = .red
                        report.notes["chapter"] = "无法抓取示例章节页面进行正文分析。请运行「测试」或在「高级修复」中手动设置 `bodyField`。"
                    }
                } else {
                    report.chapter = .red
                    report.notes["chapter"] = "目录中未发现章节链接,无法定位正文样本。请运行「测试」或在「高级修复」中手动设置。"
                }
            } else {
                report.catalog = .red
                report.notes["catalog"] = "未能识别目录结构。请在「高级修复」中手动设置 `chaptersSelector`。"
                report.detail = .red
                report.notes["detail"] = "请运行「测试」或在「高级修复」中手动设置详情选择器。"
                report.chapter = .red
                report.notes["chapter"] = "请运行「测试」或在「高级修复」中手动设置 `bodyField`。"
            }
        } else {
            // Without an example URL P4 emits red per §3.2.1; the
            // Review screen surfaces 需要检查 with steer-to-Test copy.
            report.detail = .red
            report.catalog = .red
            report.chapter = .red
            report.notes["detail"] = "提供一本书的详情页 URL 以启用详情分析,或运行「测试」手动验证。"
            report.notes["catalog"] = "缺少示例书籍 URL,无法推断目录结构。请回到上一步补充,或运行「测试」/「高级修复」。"
            report.notes["chapter"] = "依赖于目录推断,需先提供示例书籍 URL 或手动设置。"
        }

        // User-supplied chapter URL wins over P4's catalog-derived guess
        // when present — the user knows which page they want sampled, and
        // catalog crawls sometimes pick a "latest update" placeholder
        // rather than chapter 1.
        if let chapterURL = input.chapterURL {
            report.firstChapterURL = chapterURL
        }

        // Custom display name overrides the analyzer's `<title>` guess so
        // the source list shows what the user typed.
        if let custom = input.customName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            rule.name = custom
            report.suggestedName = custom
        }

        // Self-test detail + chapter using the same runtime path the
        // Test sheet uses, so the user doesn't have to figure out what
        // to type to verify the analyzer's guesses. Runs the actual
        // RuleBasedBookSource against the user-supplied detail and
        // chapter URLs; bumps the block confidence to .green when the
        // engine extracts a non-empty result. Failures leave the prior
        // .yellow/.red verdict in place — the user can still tap 修复.
        let probeSource = RuleBasedBookSource(rule: rule, loader: loader)
        if report.detail != .red, let exampleBook = input.exampleBookURL {
            if let detail = try? await probeSource.fetchDetail(url: exampleBook),
               !detail.title.trimmingCharacters(in: .whitespaces).isEmpty {
                report.detail = .green
                report.notes["detail"] = "已识别书名「\(detail.title)」。"
            }
        }
        if report.chapter != .red, let firstURL = report.firstChapterURL {
            if let content = try? await probeSource.fetchChapter(url: firstURL),
               !content.paragraphs.isEmpty {
                report.chapter = .green
                report.notes["chapter"] = "已识别正文 (\(content.paragraphs.count) 段)。"
            }
        }

        return (rule, report)
    }

    // MARK: - P2 helpers

    /// Combine the user-typed host and the post-redirect host into a
    /// minimal, deduplicated pattern list. Strip `www.` because the
    /// detection matcher treats it as a no-op subdomain.
    private static func uniqueHosts(parsedHost: String, finalHost: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for h in [parsedHost, finalHost] {
            let trimmed = h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }

    /// Pull a display name out of `<title>` or `<meta name="description">`.
    /// Common pattern: `Site Name — Tagline`. Split on long-dash family
    /// separators and keep the leading chunk; that's empirically the
    /// site name on every Chinese-language pirate book site we've
    /// fingerprinted, and the worst-case fallback is "use the full
    /// title" — still better than the bare host.
    private static func extractDisplayName(from document: Document) -> String? {
        if let titleRaw = try? document.title(), !titleRaw.isEmpty {
            let normalised = titleRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            let separators: [Character] = ["-", "—", "–", "|", "·", "_"]
            if let cutIdx = normalised.firstIndex(where: { separators.contains($0) }) {
                let head = String(normalised[..<cutIdx]).trimmingCharacters(in: .whitespaces)
                if !head.isEmpty { return head }
            }
            return normalised
        }
        if
            let meta = try? document.select("meta[name=description]").first(),
            let content = try? meta.attr("content"),
            !content.isEmpty
        {
            return content
        }
        return nil
    }

    // MARK: - P3 helpers

    private struct SearchDiscovery {
        let step: SearchStep
        let confidence: AnalysisReport.BlockConfidence
        let note: String?
    }

    /// Scan all `<form>` elements; rank by name/id/action proximity to
    /// search-flavoured tokens. First match wins; >1 viable candidate
    /// flips the result to yellow.
    private static func discoverSearchForm(
        in document: Document,
        baseURL: URL
    ) -> SearchDiscovery? {
        let forms: Elements
        do { forms = try document.select("form") }
        catch { return nil }

        let tokens = ["search", "query", "searchkey", "keyword", "keyboard", "/s", "/search"]

        var candidates: [(element: Element, score: Int)] = []
        for form in forms {
            let action = (try? form.attr("action")) ?? ""
            let id = (try? form.attr("id")) ?? ""
            let name = (try? form.attr("name")) ?? ""
            let cls = (try? form.attr("class")) ?? ""
            let combined = (action + " " + id + " " + name + " " + cls).lowercased()
            let hits = tokens.reduce(0) { $0 + (combined.contains($1) ? 1 : 0) }
            // Also inspect the form's input names — many sites name the
            // form generically but the input itself is `q` / `searchkey`.
            let inputs = (try? form.select("input").array()) ?? []
            let hasSearchInput = inputs.contains { input in
                let n = ((try? input.attr("name")) ?? "").lowercased()
                let t = ((try? input.attr("type")) ?? "").lowercased()
                if t == "search" { return true }
                return ["q", "wd", "kw", "key", "keyword", "keyboard",
                        "searchkey", "s", "query"].contains(n)
            }
            if hits > 0 || hasSearchInput {
                candidates.append((form, hits + (hasSearchInput ? 1 : 0)))
            }
        }

        guard !candidates.isEmpty else { return nil }

        candidates.sort { $0.score > $1.score }
        let winner = candidates[0].element

        guard let step = synthesizeSearchStep(form: winner, baseURL: baseURL) else {
            return nil
        }
        let confidence: AnalysisReport.BlockConfidence
        let note: String?
        if candidates.count > 1 {
            confidence = .yellow
            note = "发现多个候选搜索表单,已选用第一个;若搜索结果不正确,请在「高级修复」中调整。"
        } else {
            confidence = .green
            note = "已识别搜索表单。建议运行「测试」用真实关键词验证一次。"
        }
        return SearchDiscovery(step: step, confidence: confidence, note: note)
    }

    /// Build a `SearchStep` from a `<form>` element. Synthesizes:
    /// - `urlTemplate` — `action` resolved against the document base.
    ///   `{query}` is substituted for the search input's name in the
    ///   query string (GET) or left in the body (POST).
    /// - `bodyTemplate` — POST only; URL-encoded `name=value` pairs
    ///   with `{query}` swapped in for the search input's value.
    /// - `resultsSelector` — `.result, .result-item, .search-result li`
    ///   placeholder that the user will almost certainly need to
    ///   refine. Phrased so it's obvious in 高级修复 that this is a
    ///   guess.
    private static func synthesizeSearchStep(form: Element, baseURL: URL) -> SearchStep? {
        let actionRaw = (try? form.attr("action")) ?? ""
        let methodRaw = ((try? form.attr("method")) ?? "get").lowercased()
        let method: SearchStep.Method = (methodRaw == "post") ? .post : .get

        // Find the search input — same heuristics as the picker above.
        let inputs = (try? form.select("input").array()) ?? []
        let searchInput: Element? = inputs.first { input in
            let n = ((try? input.attr("name")) ?? "").lowercased()
            let t = ((try? input.attr("type")) ?? "").lowercased()
            if t == "search" { return true }
            return ["q", "wd", "kw", "key", "keyword", "keyboard",
                    "searchkey", "s", "query"].contains(n)
        }
        guard
            let searchInput,
            let queryName = try? searchInput.attr("name"),
            !queryName.isEmpty
        else { return nil }

        // Resolve action against the base URL.
        let actionURL: URL
        if actionRaw.isEmpty {
            actionURL = baseURL
        } else if let abs = URL(string: actionRaw, relativeTo: baseURL)?.absoluteURL {
            actionURL = abs
        } else {
            return nil
        }

        var urlTemplate: String = actionURL.absoluteString
        var bodyTemplate: String? = nil

        if method == .get {
            // Drop any existing query string on the action; rebuild
            // from form inputs with `{query}` for the search field.
            var comps = URLComponents(url: actionURL, resolvingAgainstBaseURL: false)
            comps?.query = nil
            let base = comps?.url?.absoluteString ?? actionURL.absoluteString
            let pairs = formQueryPairs(inputs: inputs, queryName: queryName)
            urlTemplate = base + "?" + pairs.joined(separator: "&")
        } else {
            let pairs = formQueryPairs(inputs: inputs, queryName: queryName)
            bodyTemplate = pairs.joined(separator: "&")
        }

        return SearchStep(
            method: method,
            urlTemplate: urlTemplate,
            bodyTemplate: bodyTemplate,
            queryEncoding: .utf8,
            resultsSelector: ".result, .result-item, .search-result li",
            titleField: FieldSelector(selector: "a", attribute: "text"),
            detailURLField: FieldSelector(
                selector: "a",
                attribute: "href",
                transforms: [.absoluteURL]
            ),
            authorField: nil,
            coverField: nil,
            snippetField: nil
        )
    }

    private struct DerivedSearch {
        let step: SearchStep
        let confidence: AnalysisReport.BlockConfidence
        let note: String?
    }

    private struct SearchResultsDiscovery {
        let resultsSelector: String
        let titleField: FieldSelector
        let detailURLField: FieldSelector
        let confidence: AnalysisReport.BlockConfidence
        let note: String?
    }

    /// Execute the provided `SearchStep` with the user's keyword and
    /// locate the densest cluster of anchor-bearing rows whose links
    /// point at distinct, same-host detail-page paths in the response.
    /// Mirrors the catalog P4 cluster heuristic but tuned for search
    /// pages: fewer expected rows (≥ 3), stricter same-host check, and
    /// distinct-path filter that rules out navbars / tag clouds whose
    /// anchors all point at the same landing page.
    ///
    /// Works for both GET and POST search — the step carries `method` +
    /// `bodyTemplate`, so this function is called from both the
    /// URL-derived branch and the homepage-form-discovery branch. The
    /// substitution mirrors `verifySearch`: percent-encode the keyword
    /// for the URL/body. Real runtime requests honour `queryEncoding`
    /// for GBK/GB18030 sites; this analyzer step is best-effort.
    ///
    /// Returns refined `resultsSelector / titleField / detailURLField`
    /// so the user almost never has to open 高级修复 for common Chinese
    /// book sites.
    private static func analyzeSearchResults(
        step: SearchStep,
        keyword: String,
        homepage: URL,
        encoding: SourceEncoding,
        loader: any SourceHTMLLoading
    ) async -> SearchResultsDiscovery? {
        let encoded = keyword.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) ?? keyword
        let urlString = step.urlTemplate.replacingOccurrences(
            of: "{query}", with: encoded
        )
        guard let url = URL(string: urlString) else { return nil }

        var bodyData: Data? = nil
        if let bodyTemplate = step.bodyTemplate {
            let bodyString = bodyTemplate.replacingOccurrences(
                of: "{query}", with: encoded
            )
            bodyData = bodyString.data(using: .utf8)
        }

        let method: SourceRequest.Method = (step.method == .post) ? .post : .get
        let request = SourceRequest(
            url: url,
            method: method,
            headers: [:],
            body: bodyData,
            encoding: encoding,
            referer: nil
        )

        let snapshot: WebPageSnapshot
        do { snapshot = try await loader.fetchHTML(request) }
        catch { return nil }
        guard let document = try? SwiftSoup.parse(
            snapshot.html, snapshot.finalURL.absoluteString
        ) else { return nil }

        let homepageHost = (homepage.host(percentEncoded: false) ?? "").lowercased()
        let homepagePath = homepage.path
        let baseURL = snapshot.finalURL

        let containers: Elements
        do { containers = try document.select("ul, ol, dl, div, table, tbody") }
        catch { return nil }

        struct Cluster {
            let container: Element
            let rowTag: String
            let rowCount: Int
            let distinctPaths: Int
        }

        var clusters: [Cluster] = []
        for container in containers {
            let children = container.children().array()
            guard children.count >= 3 else { continue }
            var byTag: [String: [Element]] = [:]
            for child in children {
                byTag[child.tagName().lowercased(), default: []].append(child)
            }
            for (tag, group) in byTag {
                guard ["li", "dt", "tr", "div", "p", "article"].contains(tag),
                      group.count >= 3 else { continue }
                var hrefRowCount = 0
                var distinctPaths = Set<String>()
                for row in group {
                    let anchors = (try? row.select("a[href]").array()) ?? []
                    guard let first = anchors.first else { continue }
                    let href = (try? first.attr("href")) ?? ""
                    if href.isEmpty || href.hasPrefix("#") || href.hasPrefix("javascript:") {
                        continue
                    }
                    guard
                        let abs = URL(string: href, relativeTo: baseURL)?.absoluteURL,
                        let host = abs.host(percentEncoded: false)?.lowercased(),
                        homepageHost.isEmpty || host == homepageHost
                            || host.hasSuffix("." + homepageHost)
                            || homepageHost.hasSuffix("." + host)
                    else { continue }
                    let path = abs.path
                    guard !path.isEmpty, path != "/", path != homepagePath else { continue }
                    hrefRowCount += 1
                    distinctPaths.insert(path)
                }
                // Most rows must point at distinct paths — otherwise we
                // picked up a sidebar / pagination row where every link
                // goes to the same target.
                if hrefRowCount >= 3, distinctPaths.count * 3 >= hrefRowCount * 2 {
                    clusters.append(Cluster(
                        container: container,
                        rowTag: tag,
                        rowCount: hrefRowCount,
                        distinctPaths: distinctPaths.count
                    ))
                }
            }
        }

        if clusters.isEmpty {
            // Empty-results fallback: a non-existent keyword (e.g. user
            // pasted a typo) takes us here because the response contains
            // no rows to cluster on. But Chinese book CMSes still emit
            // the empty results container with a named class — e.g.
            // xbanxia.cc renders `<div class="pop-books2"><ol></ol></div>`
            // even on 0 hits. Walk those empty lists, look for a results
            // signal on the element or a near ancestor, and infer the
            // selector anyway so the user only needs to retry with a
            // known-good keyword (not also hand-edit selectors).
            let resultTokens = [
                "result", "search", "book", "novel", "story",
                "list", "items", "rows"
            ]
            let listEls = (try? document.select("ol, ul, tbody").array()) ?? []
            for el in listEls {
                guard el.children().array().isEmpty else { continue }
                var ancestor: Element? = el
                var hops = 0
                var matched: Element? = nil
                while let node = ancestor, hops <= 2 {
                    let id = ((try? node.id()) ?? "").lowercased()
                    let cls = ((try? node.className()) ?? "").lowercased()
                    if resultTokens.contains(where: { id.contains($0) || cls.contains($0) }) {
                        matched = node
                        break
                    }
                    ancestor = node.parent()
                    hops += 1
                }
                guard let matched else { continue }
                let rowTag = (el.tagName().lowercased() == "tbody") ? "tr" : "li"
                let containerSelector: String
                if matched === el {
                    containerSelector = selectorPath(for: el) ?? el.tagName().lowercased()
                } else {
                    let outer = selectorPath(for: matched) ?? matched.tagName().lowercased()
                    containerSelector = "\(outer) \(el.tagName().lowercased())"
                }
                let resultsSelector = "\(containerSelector) > \(rowTag)"
                return SearchResultsDiscovery(
                    resultsSelector: resultsSelector,
                    titleField: FieldSelector(selector: "a", attribute: nil, transforms: [.trim]),
                    detailURLField: FieldSelector(
                        selector: "a",
                        attribute: "href",
                        transforms: [.absoluteURL]
                    ),
                    confidence: .yellow,
                    note: "搜索请求成功,但「\(keyword)」未匹配到结果。已根据页面结构推断结果选择器 `\(resultsSelector)`,请用该网站肯定收录的关键词(如某本书名)重新「测试」验证。"
                )
            }
            return nil
        }
        clusters.sort { $0.rowCount > $1.rowCount }
        let winner = clusters[0]

        let containerSelector = selectorPath(for: winner.container)
            ?? winner.container.tagName().lowercased()
        let resultsSelector = "\(containerSelector) > \(winner.rowTag)"

        let confidence: AnalysisReport.BlockConfidence
        let note: String?
        if winner.rowCount >= 5
            && (clusters.count == 1 || winner.rowCount >= 2 * clusters[1].rowCount) {
            confidence = .green
            note = "识别到 \(winner.rowCount) 条搜索结果(`\(resultsSelector)`)。"
        } else if clusters.count > 1 && clusters[1].rowCount * 2 > winner.rowCount {
            confidence = .yellow
            note = "搜索结果候选多于一个 (\(winner.rowCount) vs \(clusters[1].rowCount));已选用最大者,如不正确请在「高级修复」中调整 `resultsSelector`。"
        } else {
            confidence = .yellow
            note = "搜索结果较少 (\(winner.rowCount) 条),请运行「测试」验证。"
        }

        return SearchResultsDiscovery(
            resultsSelector: resultsSelector,
            titleField: FieldSelector(selector: "a", attribute: nil, transforms: [.trim]),
            detailURLField: FieldSelector(
                selector: "a",
                attribute: "href",
                transforms: [.absoluteURL]
            ),
            confidence: confidence,
            note: note
        )
    }

    /// Derive a `SearchStep` deterministically from a search-results URL
    /// the user pasted from their browser. GET method is assumed because
    /// pasted URLs come from the address bar (POST forms don't preserve
    /// the body in the URL). The keyword's occurrence — plain or
    /// UTF-8/GBK percent-encoded — is replaced with the `{query}` token
    /// so the engine can substitute future queries.
    ///
    /// Returns `nil` if the keyword can't be located in the URL — in
    /// that case the caller falls back to homepage form discovery.
    private static func deriveSearchFromURL(
        searchURL: URL,
        keyword: String
    ) -> DerivedSearch? {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let urlString = searchURL.absoluteString
        var template: String? = nil
        var queryEncoding: SourceEncoding = .utf8

        // 1) Plain occurrence (ASCII keyword or unencoded CJK).
        if urlString.contains(trimmed) {
            template = urlString.replacingOccurrences(of: trimmed, with: "{query}")
        }

        // 2) UTF-8 percent-encoded.
        if template == nil,
           let utf8Encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           urlString.range(of: utf8Encoded, options: .caseInsensitive) != nil {
            template = urlString.replacingOccurrences(
                of: utf8Encoded,
                with: "{query}",
                options: .caseInsensitive
            )
            queryEncoding = .utf8
        }

        // 3) GBK / GB18030 percent-encoded. Legacy Chinese book CMSes
        // (DZBook 3.0, JieQi, etc.) still ship GB18030 search forms.
        if template == nil {
            for encoding in [String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))),
                             String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GBK_95.rawValue)))] {
                guard let data = trimmed.data(using: encoding) else { continue }
                let percent = data.map { String(format: "%%%02X", $0) }.joined()
                if urlString.range(of: percent, options: .caseInsensitive) != nil {
                    template = urlString.replacingOccurrences(
                        of: percent,
                        with: "{query}",
                        options: .caseInsensitive
                    )
                    queryEncoding = .gb18030
                    break
                }
            }
        }

        guard let urlTemplate = template else { return nil }

        let step = SearchStep(
            method: .get,
            urlTemplate: urlTemplate,
            bodyTemplate: nil,
            queryEncoding: queryEncoding,
            // Placeholder selectors — Slice B will replace these with
            // HTML-driven detection from the live search response. Until
            // then the user can refine in 高级修复 or run Test to iterate.
            resultsSelector: ".result, .result-item, .search-result li, li",
            titleField: FieldSelector(selector: "a", attribute: nil, transforms: [.trim]),
            detailURLField: FieldSelector(
                selector: "a",
                attribute: "href",
                transforms: [.absoluteURL]
            ),
            authorField: nil,
            coverField: nil,
            snippetField: nil
        )
        return DerivedSearch(
            step: step,
            confidence: .yellow,
            note: "已根据搜索 URL 推断搜索接口;结果选择器为占位值,请运行「测试」验证。"
        )
    }

    /// Build the URL/body name=value list for the form, substituting
    /// `{query}` for the search input's value. Skip submit buttons and
    /// inputs without a `name`. Values are left raw — the engine's
    /// URLTemplate substitution handles percent-encoding at request
    /// time.
    private static func formQueryPairs(inputs: [Element], queryName: String) -> [String] {
        var pairs: [String] = []
        for input in inputs {
            let name = (try? input.attr("name")) ?? ""
            guard !name.isEmpty else { continue }
            let type = ((try? input.attr("type")) ?? "").lowercased()
            if type == "submit" || type == "button" || type == "image" { continue }
            if name == queryName {
                pairs.append("\(name)={query}")
            } else {
                let v = (try? input.attr("value")) ?? ""
                pairs.append("\(name)=\(v)")
            }
        }
        return pairs
    }

    // MARK: - P3 verification

    private struct VerifyVerdict {
        let confidence: AnalysisReport.BlockConfidence
        let note: String?
    }

    /// Execute the proposed search and inspect the response. Green iff
    /// the page parses and the proposed `resultsSelector` matches at
    /// least one element. Yellow when the page loads but the selector
    /// returns nothing — that's almost always a wrong-selector problem,
    /// and the user can fix it in 高级修复. Red when the request itself
    /// fails.
    private static func verifySearch(
        step: SearchStep,
        keyword: String,
        encoding: SourceEncoding,
        loader: any SourceHTMLLoading
    ) async -> VerifyVerdict? {
        // Naïve substitution — good enough for a smoke test. The full
        // URLTemplate engine handles percent-encoding at runtime; this
        // path is best-effort verification only.
        let encoded = keyword.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) ?? keyword
        let urlString = step.urlTemplate.replacingOccurrences(of: "{query}", with: encoded)
        guard let url = URL(string: urlString) else { return nil }

        var bodyData: Data? = nil
        if let bodyTemplate = step.bodyTemplate {
            let bodyString = bodyTemplate.replacingOccurrences(of: "{query}", with: encoded)
            bodyData = bodyString.data(using: .utf8)
        }

        let method: SourceRequest.Method = (step.method == .post) ? .post : .get
        let request = SourceRequest(
            url: url,
            method: method,
            headers: [:],
            body: bodyData,
            encoding: encoding,
            referer: nil
        )

        let snapshot: WebPageSnapshot
        do { snapshot = try await loader.fetchHTML(request) }
        catch {
            return VerifyVerdict(
                confidence: .red,
                note: "搜索请求失败:\(error.localizedDescription)"
            )
        }
        guard let document = try? SwiftSoup.parse(snapshot.html, snapshot.finalURL.absoluteString) else {
            return VerifyVerdict(
                confidence: .yellow,
                note: "搜索响应无法解析为 HTML,请在「高级修复」中调整或切换引擎。"
            )
        }
        let matches = (try? document.select(step.resultsSelector).array()) ?? []
        if matches.isEmpty {
            return VerifyVerdict(
                confidence: .yellow,
                note: "搜索请求成功,但默认结果选择器未命中。请在「高级修复」中调整 `resultsSelector`。"
            )
        }
        return VerifyVerdict(
            confidence: .green,
            note: "搜索冒烟测试通过 (\(matches.count) 条结果)。"
        )
    }

    // MARK: - P4 catalog detection

    private struct CatalogDiscovery {
        let chaptersSelector: String
        let titleField: FieldSelector
        let urlField: FieldSelector
        let firstChapterURL: URL?
        let confidence: AnalysisReport.BlockConfidence
        let note: String?
    }

    /// Fetch the example book page and identify the densest cluster of
    /// anchor-bearing sibling rows. The cluster's parent container plus
    /// the dominant child tag give us `chaptersSelector`; per-row
    /// `<a>` gives us `titleField` (text) and `urlField` (href, with
    /// `.absoluteURL` so the engine resolves relative chapter links
    /// against the book page's base URL).
    ///
    /// Confidence:
    /// - green when one container dominates (≥ 2x the runner-up's row
    ///   count) and has ≥ 10 rows.
    /// - yellow when multiple containers tie or the row count is low
    ///   (5–9). The user almost certainly needs to tweak in 高级修复.
    /// - returns nil when no container has ≥ 5 anchor-bearing rows.
    private static func analyzeCatalog(
        exampleBookURL: URL,
        encoding: SourceEncoding,
        loader: any SourceHTMLLoading
    ) async -> CatalogDiscovery? {
        let request = SourceRequest(url: exampleBookURL, method: .get, encoding: encoding)
        let snapshot: WebPageSnapshot
        do { snapshot = try await loader.fetchHTML(request) }
        catch { return nil }
        guard let document = try? SwiftSoup.parse(
            snapshot.html, snapshot.finalURL.absoluteString
        ) else { return nil }

        // Walk every container that's a plausible list shape.
        let containers: Elements
        do { containers = try document.select("ul, ol, dl, div, table, tbody") }
        catch { return nil }

        struct Cluster {
            let container: Element
            let rowTag: String
            let rowCount: Int
            let firstAnchorHref: String
        }

        var clusters: [Cluster] = []
        for container in containers {
            let children = container.children().array()
            guard children.count >= 5 else { continue }
            // Group children by tag name to find the dominant row shape.
            var byTag: [String: [Element]] = [:]
            for child in children {
                byTag[child.tagName().lowercased(), default: []].append(child)
            }
            for (tag, group) in byTag {
                guard ["li", "dd", "tr", "div", "p"].contains(tag),
                      group.count >= 5 else { continue }
                var hrefRowCount = 0
                var firstHref = ""
                for row in group {
                    let anchors = (try? row.select("a[href]").array()) ?? []
                    guard let first = anchors.first else { continue }
                    let href = (try? first.attr("href")) ?? ""
                    if href.isEmpty || href.hasPrefix("#") || href.hasPrefix("javascript:") {
                        continue
                    }
                    hrefRowCount += 1
                    if firstHref.isEmpty { firstHref = href }
                }
                if hrefRowCount >= 5 {
                    clusters.append(Cluster(
                        container: container,
                        rowTag: tag,
                        rowCount: hrefRowCount,
                        firstAnchorHref: firstHref
                    ))
                }
            }
        }

        guard !clusters.isEmpty else { return nil }
        clusters.sort { $0.rowCount > $1.rowCount }
        let winner = clusters[0]

        // Build a CSS path for the container. ID > first class > tag.
        let containerSelector = selectorPath(for: winner.container) ?? winner.container.tagName().lowercased()
        let chaptersSelector = "\(containerSelector) > \(winner.rowTag)"

        // Resolve the first chapter link to give P5 a probe target.
        let firstChapterURL = URL(
            string: winner.firstAnchorHref,
            relativeTo: snapshot.finalURL
        )?.absoluteURL

        let confidence: AnalysisReport.BlockConfidence
        let note: String?
        if winner.rowCount >= 10 && (clusters.count == 1 || winner.rowCount >= 2 * clusters[1].rowCount) {
            confidence = .green
            note = "识别到 \(winner.rowCount) 行候选目录(`\(chaptersSelector)`)。建议运行「测试」验证。"
        } else if clusters.count > 1 && clusters[1].rowCount * 2 > winner.rowCount {
            confidence = .yellow
            note = "目录候选多于一个 (rowCount \(winner.rowCount) vs \(clusters[1].rowCount));已选用最大者,如不正确请在「高级修复」中调整。"
        } else {
            confidence = .yellow
            note = "目录行数较少 (\(winner.rowCount) 行),请运行「测试」验证。"
        }

        return CatalogDiscovery(
            chaptersSelector: chaptersSelector,
            titleField: FieldSelector(selector: "a", attribute: nil, transforms: []),
            urlField: FieldSelector(
                selector: "a",
                attribute: "href",
                transforms: [.absoluteURL]
            ),
            firstChapterURL: firstChapterURL,
            confidence: confidence,
            note: note
        )
    }

    /// CSS path heuristic for an element. Prefer `#id` for stability,
    /// then `.first-class` (most stable single class), then bare tag.
    /// Never tries to build a multi-level path — that's brittle and
    /// users hand-edit any wrong guess in 高级修复 anyway.
    private static func selectorPath(for element: Element) -> String? {
        if let id = try? element.id(), !id.isEmpty {
            return "#\(id)"
        }
        if let classNames = try? element.className(), !classNames.isEmpty {
            let parts = classNames.split(whereSeparator: { $0.isWhitespace })
            if let first = parts.first {
                let cls = String(first)
                if !cls.isEmpty { return ".\(cls)" }
            }
        }
        return nil
    }

    // MARK: - P5 chapter-body detection

    private struct ChapterBodyDiscovery {
        let bodyField: FieldSelector
        let confidence: AnalysisReport.BlockConfidence
        let note: String?
    }

    /// Fetch the first proposed chapter and locate the highest
    /// text-density block. Default `bodyField` transforms are
    /// `.brToNewline` (preserve line breaks from `<br>`) and
    /// `.stripHTML` (drop residual markup), matching the seeded
    /// rules' chapter-body conventions.
    ///
    /// Heuristic: prefer elements whose class/id matches the
    /// common Chinese-novel-site vocabulary (`content`, `chapter`,
    /// `text`, `articlebody`, etc.); fall back to longest plain-text
    /// block when no match.
    private static func analyzeChapterBody(
        chapterURL: URL,
        encoding: SourceEncoding,
        loader: any SourceHTMLLoading
    ) async -> ChapterBodyDiscovery? {
        let request = SourceRequest(url: chapterURL, method: .get, encoding: encoding)
        let snapshot: WebPageSnapshot
        do { snapshot = try await loader.fetchHTML(request) }
        catch { return nil }
        guard let document = try? SwiftSoup.parse(
            snapshot.html, snapshot.finalURL.absoluteString
        ) else { return nil }

        // Sweep candidate elements. We're after the largest contiguous
        // text block on the page.
        let candidates: Elements
        do {
            candidates = try document.select(
                "div, article, section, pre, .content, .chapter, #content, #chapter"
            )
        } catch { return nil }

        let knownContentTokens = [
            "content", "chapter", "chaptercontent", "articlebody",
            "article-body", "text", "txt", "novel", "read", "story"
        ]

        struct Candidate {
            let element: Element
            let textLength: Int
            let isPreferredName: Bool
        }

        var winners: [Candidate] = []
        for el in candidates {
            let text: String
            do { text = try el.text() } catch { continue }
            let len = text.count
            guard len >= 300 else { continue }
            let id = ((try? el.id()) ?? "").lowercased()
            let cls = ((try? el.className()) ?? "").lowercased()
            let preferred = knownContentTokens.contains { id.contains($0) || cls.contains($0) }
            winners.append(Candidate(element: el, textLength: len, isPreferredName: preferred))
        }

        guard !winners.isEmpty else { return nil }

        // Drop wrapping candidates. If A is an ancestor of B and both
        // qualify, A picks up B's text *plus* whatever else is on the
        // page (header, nav, footer, recommendations). Reading from A
        // dumps the entire page chrome into every chapter; reading
        // from the leaf-most B gives just the body. xbanxia is the
        // motivating case — both `#pagewrap` (whole page) and `#nr1`
        // (chapter body) clear the 300-char threshold and neither
        // matches `knownContentTokens`, so length alone picks the
        // wrapper. Pruning ancestors keeps `#nr1`.
        let pruned: [Candidate] = winners.filter { outer in
            !winners.contains { inner in
                inner.element !== outer.element
                    && Self.isAncestor(outer.element, of: inner.element)
            }
        }
        let leafs = pruned.isEmpty ? winners : pruned

        // Preferred names win ties even when shorter — class-based
        // signals are dramatically more reliable than length on noisy
        // pages with sidebars + comments.
        let sorted = leafs.sorted { lhs, rhs in
            if lhs.isPreferredName != rhs.isPreferredName { return lhs.isPreferredName }
            return lhs.textLength > rhs.textLength
        }
        let winner = sorted[0]

        guard let selector = selectorPath(for: winner.element) else {
            return ChapterBodyDiscovery(
                bodyField: FieldSelector(
                    selector: "body",
                    attribute: "html",
                    transforms: [.brToNewline, .stripHTML, .decodeHTMLEntities]
                ),
                confidence: .yellow,
                note: "未找到稳定的正文容器,已退化为整页文本。请在「高级修复」中设置精确的 `bodyField` 选择器。"
            )
        }

        let confidence: AnalysisReport.BlockConfidence = winner.isPreferredName
            ? .green
            : .yellow
        let note = winner.isPreferredName
            ? "识别到正文容器 `\(selector)` (\(winner.textLength) 字)。"
            : "正文容器 `\(selector)` 系按文本长度推断 (\(winner.textLength) 字),请运行「测试」验证。"

        // `attribute: "html"` + `brToNewline` is the only way to keep
        // paragraph breaks from `<br>` separators — Element.text() would
        // collapse them to spaces before any transform runs. Matches
        // the seeded rule conventions; `decodeHTMLEntities` cleans up
        // the residual `&nbsp;` / numeric refs left after stripHTML.
        return ChapterBodyDiscovery(
            bodyField: FieldSelector(
                selector: selector,
                attribute: "html",
                transforms: [.brToNewline, .stripHTML, .decodeHTMLEntities]
            ),
            confidence: confidence,
            note: note
        )
    }

    private static func isAncestor(_ ancestor: Element, of descendant: Element) -> Bool {
        guard let parents = try? descendant.parents() else { return false }
        for p in parents where p === ancestor { return true }
        return false
    }
}
