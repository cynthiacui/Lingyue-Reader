import XCTest
@testable import LingyueCore

/// Covers the single-match search redirect: legacy CMS backends (杰奇 —
/// 半夏小说 and friends) 302 a uniquely-matching search query straight to
/// the book's detail page, so the results-list selector matches nothing.
/// The engine must recognize the landing page via the rule's `detection`
/// block and synthesize the one hit — and must NOT synthesize anything
/// from an ordinary empty results page.
final class SearchRedirectFallbackTests: XCTestCase {

    // MARK: - Stub loader

    /// Returns a canned snapshot whose `finalURL` can differ from the
    /// requested URL, mimicking a loader that followed a redirect.
    private struct RedirectLoader: SourceHTMLLoading {
        let html: String
        let finalURL: URL

        func fetchHTML(_ request: SourceRequest) async throws -> WebPageSnapshot {
            WebPageSnapshot(html: html, finalURL: finalURL, responseHeaders: [:], statusCode: 200)
        }

        func renderHTML(_ request: SourceRequest) async throws -> WebPageSnapshot {
            try await fetchHTML(request)
        }
    }

    // MARK: - Fixtures

    private static let detailPageHTML = """
    <html><head>
      <title>第二人格[規則怪談] - 半夏小說</title>
      <link rel="canonical" href="https://www.example-novel.cc/books/408368.html">
    </head><body>
      <h1 id="logo"><a href="/">半夏小說</a></h1>
      <div class="book-describe">
        <h1>第二人格[規則怪談]</h1>
        <p>作者：織朱</p>
      </div>
      <div class="book-list"><ul><li><a href="/books/408368/1.html">第一章</a></li></ul></div>
    </body></html>
    """

    private static let emptyResultsHTML = """
    <html><head><title>搜索结果</title></head><body>
      <h1 id="logo"><a href="/">半夏小說</a></h1>
      <div class="search-tip">没有找到相关小说</div>
    </body></html>
    """

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
            detection: DetectionStep(
                hostPatterns: ["example-novel.cc", "www.example-novel.cc"],
                pathPattern: #"^/books/\d+\.html$"#,
                confirmSelector: "h1, div.book-info"
            ),
            search: SearchStep(
                method: .get,
                urlTemplate: "https://www.example-novel.cc/search.php?searchkey={query}",
                resultsSelector: "li.pop-book2",
                titleField: FieldSelector(selector: "h2.pop-tit"),
                detailURLField: FieldSelector(selector: "a[title]", attribute: "href")
            ),
            detail: DetailStep(
                titleField: FieldSelector(selector: "div.book-describe h1, h1:not(#logo):not(.logo)"),
                catalogURLField: FieldSelector(selector: "link[rel=canonical]", attribute: "href")
            ),
            catalog: CatalogStep(
                chaptersSelector: "div.book-list ul li a",
                titleField: FieldSelector(),
                urlField: FieldSelector(attribute: "href")
            ),
            chapter: ChapterStep(
                titleField: FieldSelector(selector: "h1"),
                bodyField: FieldSelector(selector: "div")
            )
        )
    }

    // MARK: - Tests

    func testSingleMatchRedirectSynthesizesOneHit() async throws {
        let rule = makeRule()
        let loader = RedirectLoader(
            html: Self.detailPageHTML,
            finalURL: URL(string: "https://www.example-novel.cc/books/408368.html")!
        )
        let source = RuleBasedBookSource(rule: rule, loader: loader)

        let hits = try await source.search("第二人格[规则怪谈]")

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.title, "第二人格[規則怪談]")
        // Detail URL comes from the detection's canonical resolution.
        XCTAssertEqual(
            hits.first?.detailURL.absoluteString,
            "https://www.example-novel.cc/books/408368.html"
        )
    }

    func testEmptyResultsPageStaysEmpty() async throws {
        let rule = makeRule()
        // No redirect: the loader stays on the search endpoint. Its path
        // fails the rule's pathPattern, so the confidence gate must hold
        // the fallback shut even though the page has an <h1> that would
        // satisfy the confirm selector.
        let loader = RedirectLoader(
            html: Self.emptyResultsHTML,
            finalURL: URL(string: "https://www.example-novel.cc/search.php?searchkey=x")!
        )
        let source = RuleBasedBookSource(rule: rule, loader: loader)

        let hits = try await source.search("不存在的书名")

        XCTAssertTrue(hits.isEmpty)
    }
}

// MARK: - Challenge screen

final class ChallengePageScreenTests: XCTestCase {

    func testCloudflareInterstitialByToken() {
        let html = """
        <html><head><title>请稍候…</title></head>
        <body><form action="/x?__cf_chl_rt_tk=abc"><script>window._cf_chl_opt={};</script></form></body></html>
        """
        XCTAssertTrue(ChallengePageScreen.isChallenge(html))
    }

    func testCloudflareInterstitialByTitleOnly() {
        XCTAssertTrue(ChallengePageScreen.isChallenge(
            "<html><head><title>Just a moment...</title></head><body></body></html>"
        ))
        XCTAssertTrue(ChallengePageScreen.isChallenge(
            "<html><head><title>请稍候…</title></head><body></body></html>"
        ))
    }

    func testBookPageMentioningWaitTextIsNotChallenge() {
        // 「请稍候」 in body copy must not trip the title-anchored patterns,
        // and CF's *invisible* bot-management beacon on ordinary proxied
        // pages must not count as an interstitial.
        let html = """
        <html><head><title>第五章 请稍候片刻 - 某书</title>
        <script src="/cdn-cgi/challenge-platform/scripts/jsd/main.js"></script></head>
        <body><p>他说：请稍候…</p></body></html>
        """
        XCTAssertFalse(ChallengePageScreen.isChallenge(html))
    }
}
