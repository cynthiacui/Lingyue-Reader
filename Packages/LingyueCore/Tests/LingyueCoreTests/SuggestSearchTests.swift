import XCTest
@testable import LingyueCore

/// Tests for the suggest-assisted search path + separator normalization
/// (`SearchStep.suggest` / `SearchStep.normalizeQuerySeparators`).
///
/// Models the real 52书库 quirk: `search.php` is a full-text search that
/// buries short title queries ("霸宠" never returns "霸宠_笑佳人【完结】"),
/// while `suggest.php?term=…` prefix-matches titles and each suggestion fed
/// back into the search returns the exact book. The stub loader reproduces
/// exactly that asymmetry so the test fails if the engine ever stops
/// consulting the suggest endpoint.
final class SuggestSearchTests: XCTestCase {

    // MARK: - Stub loader

    /// Routes by endpoint + *decoded* query param, so it's immune to
    /// percent-encoding differences (spaces, Hanzi). `suggest` → JSON string
    /// array; `search` → 52书库-shaped `article.excerpt` rows.
    private struct StubLoader: SourceHTMLLoading {
        /// `term` value → suggestion strings.
        let suggestions: [String: [String]]
        /// `q` value → result rows (title, absolute detail URL).
        let searchResults: [String: [(title: String, url: String)]]

        func fetchHTML(_ request: SourceRequest) async throws -> WebPageSnapshot {
            let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
            let body: String
            if request.url.path.contains("suggest") {
                let term = components?.queryItems?.first { $0.name == "term" }?.value ?? ""
                let list = suggestions[term] ?? []
                let data = try JSONEncoder().encode(list)
                body = String(data: data, encoding: .utf8) ?? "[]"
            } else {
                let query = components?.queryItems?.first { $0.name == "q" }?.value ?? ""
                let rows = (searchResults[query] ?? [])
                    .map { #"<article class="excerpt"><a href="\#($0.url)"><h4>\#($0.title)</h4></a></article>"# }
                    .joined()
                body = "<html><body>\(rows)</body></html>"
            }
            return WebPageSnapshot(
                html: body,
                finalURL: request.url,
                responseHeaders: [:],
                statusCode: 200
            )
        }

        func renderHTML(_ request: SourceRequest) async throws -> WebPageSnapshot {
            try await fetchHTML(request)
        }
    }

    // MARK: - Rule builder

    private func makeRule(
        normalizeQuerySeparators: Bool,
        suggest: SuggestStep?
    ) -> SourceRule {
        SourceRule(
            name: "52书库",
            homepage: URL(string: "https://www.52shuku.net/")!,
            capabilities: SourceCapabilities(
                supportsSearch: true,
                showInSearchBar: true,
                supportsBrowserImport: true,
                requiresWebRender: false
            ),
            detection: DetectionStep(hostPatterns: ["52shuku.net"]),
            search: SearchStep(
                method: .get,
                urlTemplate: "https://www.52shuku.net/so/search.php?q={query}",
                resultsSelector: "article.excerpt",
                titleField: FieldSelector(selector: "a h4"),
                detailURLField: FieldSelector(selector: "a", attribute: "href"),
                normalizeQuerySeparators: normalizeQuerySeparators,
                suggest: suggest
            ),
            detail: DetailStep(
                titleField: FieldSelector(selector: "h1"),
                catalogURLField: FieldSelector(selector: "link", attribute: "href")
            ),
            catalog: CatalogStep(
                chaptersSelector: "a",
                titleField: FieldSelector(),
                urlField: FieldSelector(attribute: "href")
            ),
            chapter: ChapterStep(
                titleField: FieldSelector(selector: "h1"),
                bodyField: FieldSelector(selector: "div")
            )
        )
    }

    private let suggestStep = SuggestStep(
        urlTemplate: "https://www.52shuku.net/so/suggest.php?term={query}",
        maxSuggestions: 6
    )

    private let targetURL = "https://www.52shuku.net/jiakong/1914.html"

    // MARK: - The headline case: bare title finds the munged book

    func testBareTitleSurfacesMungedBookViaSuggest() async throws {
        let loader = StubLoader(
            suggestions: ["霸宠": ["霸宠暗卫", "霸宠 笑佳人", "霸宠天下"]],
            searchResults: [
                // Full-text search of the bare title returns nothing useful —
                // exactly the real site's behaviour.
                "霸宠": [],
                "霸宠暗卫": [("霸宠暗卫_某甲【完结】", "https://www.52shuku.net/jiakong/100.html")],
                "霸宠 笑佳人": [("霸宠_笑佳人【完结】", targetURL)],
                "霸宠天下": [("霸宠天下_某乙【完结】", "https://www.52shuku.net/jiakong/200.html")]
            ]
        )
        let source = RuleBasedBookSource(
            rule: makeRule(normalizeQuerySeparators: true, suggest: suggestStep),
            loader: loader
        )

        let results = try await source.search("霸宠")
        let urls = results.map(\.detailURL.absoluteString)
        XCTAssertTrue(
            urls.contains(targetURL),
            "Bare-title search must reach the munged book via the suggest endpoint; got \(urls)"
        )
        // All three suggestion-derived books should be present.
        XCTAssertEqual(results.count, 3)
    }

    // MARK: - Paste case: `书名_作者【完结】` normalizes into a working query

    func testSeparatorNormalizationFixesPastedMungedTitle() async throws {
        let loader = StubLoader(
            // suggest deliberately returns nothing for the spaced form — proves
            // the normalized *search* query alone already finds the book.
            suggestions: [:],
            searchResults: [
                "霸宠 笑佳人": [("霸宠_笑佳人【完结】", targetURL)]
            ]
        )
        let source = RuleBasedBookSource(
            rule: makeRule(normalizeQuerySeparators: true, suggest: suggestStep),
            loader: loader
        )

        let results = try await source.search("霸宠_笑佳人【完结】")
        XCTAssertEqual(results.map(\.detailURL.absoluteString), [targetURL])
    }

    // MARK: - Backward compatibility: no suggest, no normalize → unchanged

    func testPlainRuleRunsSingleSearch() async throws {
        let loader = StubLoader(
            suggestions: ["霸宠": ["霸宠 笑佳人"]],   // must be ignored
            searchResults: [
                "霸宠": [("无关填充_某丙【完结】", "https://www.52shuku.net/jiakong/999.html")],
                "霸宠 笑佳人": [("霸宠_笑佳人【完结】", targetURL)]
            ]
        )
        let source = RuleBasedBookSource(
            rule: makeRule(normalizeQuerySeparators: false, suggest: nil),
            loader: loader
        )

        let results = try await source.search("霸宠")
        XCTAssertEqual(
            results.map(\.detailURL.absoluteString),
            ["https://www.52shuku.net/jiakong/999.html"],
            "Without a suggest step the engine must run exactly one search and not consult suggest"
        )
    }

    // MARK: - Dedup + cap

    func testDuplicateURLsAcrossQueriesAreMergedOnce() async throws {
        let loader = StubLoader(
            suggestions: ["霸宠": ["霸宠 笑佳人", "霸宠（同书）"]],
            searchResults: [
                "霸宠": [],
                "霸宠 笑佳人": [("霸宠_笑佳人【完结】", targetURL)],
                "霸宠（同书）": [("霸宠_笑佳人", targetURL)]   // same URL, different munge
            ]
        )
        let source = RuleBasedBookSource(
            rule: makeRule(normalizeQuerySeparators: true, suggest: suggestStep),
            loader: loader
        )

        let results = try await source.search("霸宠")
        XCTAssertEqual(results.filter { $0.detailURL.absoluteString == targetURL }.count, 1)
    }

    func testMaxSuggestionsCapsFanOut() async throws {
        let loader = StubLoader(
            suggestions: ["霸宠": ["霸宠A", "霸宠B", "霸宠C", "霸宠D"]],
            searchResults: [
                "霸宠": [],
                "霸宠A": [("A_x【完结】", "https://www.52shuku.net/jiakong/1.html")],
                "霸宠B": [("B_x【完结】", "https://www.52shuku.net/jiakong/2.html")],
                "霸宠C": [("C_x【完结】", "https://www.52shuku.net/jiakong/3.html")],
                "霸宠D": [("D_x【完结】", "https://www.52shuku.net/jiakong/4.html")]
            ]
        )
        let cappedSuggest = SuggestStep(
            urlTemplate: "https://www.52shuku.net/so/suggest.php?term={query}",
            maxSuggestions: 2
        )
        let source = RuleBasedBookSource(
            rule: makeRule(normalizeQuerySeparators: true, suggest: cappedSuggest),
            loader: loader
        )

        let results = try await source.search("霸宠")
        let urls = Set(results.map(\.detailURL.absoluteString))
        XCTAssertEqual(urls, [
            "https://www.52shuku.net/jiakong/1.html",
            "https://www.52shuku.net/jiakong/2.html"
        ], "Only the top 2 suggestions should be expanded; got \(urls)")
    }

    // MARK: - Pure normalization unit

    func testNormalizeQuerySeparators() {
        let cases: [(String, String)] = [
            ("霸宠_笑佳人【完结】", "霸宠 笑佳人"),
            ("霸宠", "霸宠"),
            ("霸宠｜笑佳人", "霸宠 笑佳人"),
            ("霸宠·笑佳人", "霸宠 笑佳人"),
            ("女配在线挖坑[快穿]_月下清泠【完结】", "女配在线挖坑 月下清泠"),
            ("  霸宠  ", "霸宠"),
            ("霸宠_笑佳人【完结+番外】", "霸宠 笑佳人")
        ]
        for (input, expected) in cases {
            XCTAssertEqual(
                RuleBasedBookSource.normalizeQuerySeparators(input),
                expected,
                "normalize(\(input))"
            )
        }
    }

    func testNormalizeEmptyAnnotationFallsBackToOriginalQuery() async throws {
        // A query that's *only* an annotation block normalizes to "" — the
        // engine must fall back to the raw text so the search still runs.
        let loader = StubLoader(
            suggestions: [:],
            searchResults: ["（番外）": [("番外合集_某丁", "https://www.52shuku.net/jiakong/7.html")]]
        )
        let source = RuleBasedBookSource(
            rule: makeRule(normalizeQuerySeparators: true, suggest: nil),
            loader: loader
        )
        let results = try await source.search("（番外）")
        XCTAssertEqual(results.map(\.detailURL.absoluteString), ["https://www.52shuku.net/jiakong/7.html"])
    }
}
