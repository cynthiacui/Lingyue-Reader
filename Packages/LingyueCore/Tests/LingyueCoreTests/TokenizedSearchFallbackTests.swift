import XCTest
@testable import LingyueCore

/// Covers the tokenized-search fallback: 杰奇-style backends substring-match
/// the whole query against the title, so a space-separated query
/// (`第二人格 规则怪谈` for the real title `第二人格[規則怪談]`, or `书名 作者`)
/// returns zero rows even though the book exists. The engine must retry with
/// the individual tokens and keep only hits every token appears in.
final class TokenizedSearchFallbackTests: XCTestCase {

    // MARK: - Stub loader

    /// Routes by the *decoded* `searchkey` query param and counts requests,
    /// so tests can assert both the results and the fan-out shape.
    private final class SubstringSearchLoader: SourceHTMLLoading, @unchecked Sendable {
        /// Decoded query → result rows (title, author, absolute detail URL).
        let resultsByQuery: [String: [(title: String, author: String, url: String)]]
        private let lock = NSLock()
        private(set) var requestedQueries: [String] = []

        init(resultsByQuery: [String: [(title: String, author: String, url: String)]]) {
            self.resultsByQuery = resultsByQuery
        }

        func fetchHTML(_ request: SourceRequest) async throws -> WebPageSnapshot {
            let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
            let query = components?.queryItems?.first { $0.name == "searchkey" }?.value ?? ""
            lock.lock()
            requestedQueries.append(query)
            lock.unlock()
            let rows = (resultsByQuery[query] ?? [])
                .map {
                    #"<li class="pop-book2"><a title="\#($0.title)" href="\#($0.url)">"#
                    + #"<h2 class="pop-tit">\#($0.title)</h2>"#
                    + #"<span class="author">\#($0.author)</span></a></li>"#
                }
                .joined()
            return WebPageSnapshot(
                html: "<html><body><ul>\(rows)</ul></body></html>",
                finalURL: request.url,
                responseHeaders: [:],
                statusCode: 200
            )
        }

        func renderHTML(_ request: SourceRequest) async throws -> WebPageSnapshot {
            try await fetchHTML(request)
        }
    }

    private func makeRule() -> SourceRule {
        SourceRule(
            name: "半夏小说",
            homepage: URL(string: "https://www.example-novel.cc/")!,
            capabilities: SourceCapabilities(
                supportsSearch: true,
                showInSearchBar: true,
                supportsBrowserImport: true,
                requiresWebRender: false
            ),
            detection: DetectionStep(hostPatterns: ["example-novel.cc"]),
            search: SearchStep(
                method: .get,
                urlTemplate: "https://www.example-novel.cc/search.php?searchkey={query}",
                resultsSelector: "li.pop-book2",
                titleField: FieldSelector(selector: "h2.pop-tit"),
                detailURLField: FieldSelector(selector: "a[title]", attribute: "href"),
                authorField: FieldSelector(selector: "span.author")
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

    private let target = (
        title: "第二人格[規則怪談]",
        author: "織朱",
        url: "https://www.example-novel.cc/books/408368.html"
    )

    // MARK: - The headline case: spaced title fragments find the bracketed book

    func testSpacedTitleFragmentsSurfaceBracketedTitle() async throws {
        let loader = SubstringSearchLoader(resultsByQuery: [
            // The site's literal substring search finds nothing for the
            // spaced query — exactly 半夏's real behaviour.
            "第二人格 规则怪谈": [],
            "第二人格": [
                target,
                ("第二人格", "暧昧散盡", "https://www.example-novel.cc/books/1.html"),
                ("拥有第二人格", "小欠欠2", "https://www.example-novel.cc/books/2.html")
            ],
            "规则怪谈": [target]
        ])
        let source = RuleBasedBookSource(rule: makeRule(), loader: loader)

        let hits = try await source.search("第二人格 规则怪谈")

        // Only the book containing BOTH tokens survives — the token filter
        // must also bridge simplified query ↔ traditional title — and the
        // hit found by both token searches is deduplicated by URL.
        XCTAssertEqual(hits.map(\.title), [target.title])
    }

    func testAuthorTokenMatchesAuthorField() async throws {
        let loader = SubstringSearchLoader(resultsByQuery: [
            "霸宠 笑佳人": [],
            "笑佳人": [],
            "霸宠": [
                ("霸宠", "笑佳人", "https://www.example-novel.cc/books/10.html"),
                ("霸宠暗卫", "某甲", "https://www.example-novel.cc/books/11.html")
            ]
        ])
        let source = RuleBasedBookSource(rule: makeRule(), loader: loader)

        let hits = try await source.search("霸宠 笑佳人")

        XCTAssertEqual(hits.map(\.title), ["霸宠"])
        XCTAssertEqual(hits.first?.author, "笑佳人")
    }

    func testUnspacedQueryDoesNotFanOut() async throws {
        let loader = SubstringSearchLoader(resultsByQuery: [:])
        let source = RuleBasedBookSource(rule: makeRule(), loader: loader)

        let hits = try await source.search("不存在的书")

        XCTAssertTrue(hits.isEmpty)
        // No token fallback for a single-token query: exactly one request.
        XCTAssertEqual(loader.requestedQueries, ["不存在的书"])
    }

    func testNonEmptyPrimaryResultSkipsFallback() async throws {
        let loader = SubstringSearchLoader(resultsByQuery: [
            "红楼 梦": [("红楼梦", "曹雪芹", "https://www.example-novel.cc/books/20.html")]
        ])
        let source = RuleBasedBookSource(rule: makeRule(), loader: loader)

        let hits = try await source.search("红楼 梦")

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(loader.requestedQueries, ["红楼 梦"])
    }

    // MARK: - matchingKey folding

    func testMatchingKeyFoldsBracketsWidthAndScript() {
        XCTAssertEqual(
            RuleBasedBookSource.matchingKey("第二人格[規則怪談]"),
            "第二人格规则怪谈"
        )
        XCTAssertEqual(
            RuleBasedBookSource.matchingKey("ＡＢＣ·Ｄｅｆ 【完结】"),
            "abcdef完结"
        )
    }
}
